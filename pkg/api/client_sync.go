package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"time"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/datastore"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/log"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/utils"
)

type ClientSyncApi struct{}

var ClientSync = &ClientSyncApi{}

type syncPageRequest struct {
	Count      int    `form:"count" binding:"min=0,max=500"`
	PageToken  string `form:"page_token"`
	Cursor     int64  `form:"cursor" binding:"min=0"`
	Generation int64  `form:"generation" binding:"min=0"`
}

type syncSnapshotToken struct {
	Uid        int64  `json:"u"`
	Generation int64  `json:"g"`
	Cursor     int64  `json:"c"`
	Entity     string `json:"e"`
	Id         int64  `json:"i"`
}

type syncChangeResponse struct {
	Entity  string          `json:"entity"`
	Id      int64           `json:"id,string"`
	Version int64           `json:"version,string"`
	Deleted bool            `json:"deleted"`
	Data    json.RawMessage `json:"data"`
}

// Versioned projections contain only durable business data. Permission windows
// depend on the current user, timezone and date and are decorated at read time.
func syncTransactionPresenter(c *core.WebContext, scope *datastore.SyncTransactionScope) (func(string, string) (json.RawMessage, error), error) {
	user := &models.User{}
	found, err := scope.Session.ID(scope.State.Uid).Where("deleted=?", false).Get(user)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, errs.ErrUserNotFound
	}
	zone, err := c.GetClientTimezone()
	if err != nil {
		return nil, errs.ErrClientTimezoneOffsetInvalid
	}
	var accounts []*models.Account
	if err = scope.Session.Where("uid=? AND deleted=?", scope.State.Uid, false).Find(&accounts); err != nil {
		return nil, err
	}
	byId := make(map[int64]*models.Account, len(accounts))
	for _, account := range accounts {
		byId[account.AccountId] = account
	}
	return func(entity, raw string) (json.RawMessage, error) {
		if entity != "transaction" || raw == "null" {
			return json.RawMessage(raw), nil
		}
		var transaction models.TransactionInfoResponse
		if err := json.Unmarshal([]byte(raw), &transaction); err != nil {
			return nil, err
		}
		source, destination := byId[transaction.SourceAccountId], byId[transaction.DestinationAccountId]
		transaction.Editable = syncTransactionEditable(user, &transaction, source, destination, byId, zone)
		return json.Marshal(transaction)
	}, nil
}

func syncTransactionEditable(user *models.User, transaction *models.TransactionInfoResponse, source, destination *models.Account, accounts map[int64]*models.Account, zone *time.Location) bool {
	selectable := func(account *models.Account) bool {
		if account == nil || account.Hidden || account.Deleted || account.Type != models.ACCOUNT_TYPE_SINGLE_ACCOUNT {
			return false
		}
		if account.ParentAccountId > 0 {
			parent := accounts[account.ParentAccountId]
			if parent == nil || parent.Hidden || parent.Deleted {
				return false
			}
		}
		return true
	}
	if !selectable(source) || (transaction.Type == models.TRANSACTION_TYPE_TRANSFER && !selectable(destination)) {
		return false
	}
	return user.CanEditTransactionByTransactionTime(transaction.TimeSequenceId, zone, source, destination)
}

func (a *ClientSyncApi) SnapshotHandler(c *core.WebContext) (any, *errs.Error) {
	var req syncPageRequest
	if err := c.ShouldBindQuery(&req); err != nil {
		return nil, errs.NewIncompleteOrIncorrectSubmissionError(err)
	}
	if req.Count == 0 {
		req.Count = 200
	}
	uid := c.GetCurrentUid()
	token := syncSnapshotToken{Uid: uid}
	if req.PageToken != "" {
		data, err := base64.RawURLEncoding.DecodeString(req.PageToken)
		if err != nil || len(data) > 512 || json.Unmarshal(data, &token) != nil || token.Uid != uid || token.Generation < 1 || token.Cursor < 0 || token.Id < 0 {
			return nil, errs.ErrParameterInvalid
		}
	}
	result := map[string]any{"userId": strconv.FormatInt(uid, 10), "nextPage": nil, "hasMore": false, "resetRequired": false}
	keys := map[string]string{"transaction": "transactions", "account": "accounts", "category": "categories", "tag": "tags", "tagGroup": "tagGroups", "template": "templates"}
	for _, key := range keys {
		result[key] = []json.RawMessage{}
	}
	db := datastore.Container.UserDataStore.Choose(uid)
	err := db.WithSyncTransaction(c, uid, func(scope *datastore.SyncTransactionScope) error {
		state := scope.State
		result["generation"] = strconv.FormatInt(state.Generation, 10)
		if req.PageToken == "" {
			token.Generation, token.Cursor = state.Generation, state.Cursor
		}
		result["cursor"] = strconv.FormatInt(token.Cursor, 10)
		if token.Generation != state.Generation || token.Cursor > state.Cursor {
			result["resetRequired"] = true
			return nil
		}
		present, err := syncTransactionPresenter(c, scope)
		if err != nil {
			return err
		}
		var records []*models.SyncRecord
		query := scope.Session.Where("uid=? AND (entity>? OR (entity=? AND entity_id>?))", uid, token.Entity, token.Entity, token.Id)
		if err := query.OrderBy("entity asc, entity_id asc").Limit(req.Count + 1).Find(&records); err != nil {
			return err
		}
		if len(records) > req.Count {
			result["hasMore"] = true
			records = records[:req.Count]
		}
		for _, record := range records {
			if record.Deleted {
				continue
			}
			key, valid := keys[record.Entity]
			if !valid {
				return errs.ErrOperationFailed
			}
			var data map[string]json.RawMessage
			presented, err := present(record.Entity, record.Data)
			if err != nil {
				return err
			}
			if err := json.Unmarshal(presented, &data); err != nil {
				return err
			}
			data["version"], _ = json.Marshal(strconv.FormatInt(record.Version, 10))
			encoded, err := json.Marshal(data)
			if err != nil {
				return err
			}
			result[key] = append(result[key].([]json.RawMessage), encoded)
		}
		if result["hasMore"] == true {
			last := records[len(records)-1]
			token.Entity, token.Id = last.Entity, last.EntityId
			encoded, err := json.Marshal(token)
			if err != nil {
				return err
			}
			result["nextPage"] = base64.RawURLEncoding.EncodeToString(encoded)
		}
		return nil
	})
	if err != nil {
		log.Errorf(c, "[client_sync.SnapshotHandler] synchronization failed for uid:%d, because %s", uid, err.Error())
		return nil, errs.Or(err, errs.ErrOperationFailed)
	}
	return result, nil
}

func (a *ClientSyncApi) ChangesHandler(c *core.WebContext) (any, *errs.Error) {
	var req syncPageRequest
	if err := c.ShouldBindQuery(&req); err != nil {
		return nil, errs.NewIncompleteOrIncorrectSubmissionError(err)
	}
	if req.Generation < 1 {
		return nil, errs.ErrParameterInvalid
	}
	if req.Count == 0 {
		req.Count = 200
	}
	uid := c.GetCurrentUid()
	result := map[string]any{"cursor": strconv.FormatInt(req.Cursor, 10), "hasMore": false, "resetRequired": false, "changes": []syncChangeResponse{}}
	db := datastore.Container.UserDataStore.Choose(uid)
	err := db.WithSyncTransaction(c, uid, func(scope *datastore.SyncTransactionScope) error {
		state := scope.State
		result["generation"] = strconv.FormatInt(state.Generation, 10)
		if req.Generation != state.Generation || req.Cursor > state.Cursor {
			result["resetRequired"] = true
			return nil
		}
		present, err := syncTransactionPresenter(c, scope)
		if err != nil {
			return err
		}
		var changes []*models.SyncChange
		if err := scope.Session.Where("uid=? AND "+scope.Session.Engine().Quote("cursor")+">?", uid, req.Cursor).Asc("cursor").Limit(req.Count + 1).Find(&changes); err != nil {
			return err
		}
		if len(changes) > req.Count {
			result["hasMore"] = true
			changes = changes[:req.Count]
		}
		items := make([]syncChangeResponse, 0, len(changes))
		for _, change := range changes {
			presented, err := present(change.Entity, change.Data)
			if err != nil {
				return err
			}
			items = append(items, syncChangeResponse{Entity: change.Entity, Id: change.EntityId, Version: change.Version, Deleted: change.Deleted, Data: presented})
			result["cursor"] = strconv.FormatInt(change.Cursor, 10)
		}
		result["changes"] = items
		return nil
	})
	if err != nil {
		log.Errorf(c, "[client_sync.ChangesHandler] synchronization failed for uid:%d, because %s", uid, err.Error())
		return nil, errs.Or(err, errs.ErrOperationFailed)
	}
	return result, nil
}

func syncRequestHash(req *models.SyncPushRequest) (string, error) {
	encoded, err := json.Marshal(req)
	if err != nil {
		return "", err
	}
	var normalized any
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if err = decoder.Decode(&normalized); err != nil {
		return "", err
	}
	encoded, err = json.Marshal(normalized)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(encoded)
	return hex.EncodeToString(hash[:]), nil
}

func (a *ClientSyncApi) PushHandler(c *core.WebContext) (any, *errs.Error) {
	var req models.SyncPushRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		return nil, errs.NewIncompleteOrIncorrectSubmissionError(err)
	}
	if (req.Action == "create" && (req.BaseVersion != 0 || req.TransactionId != 0)) || (req.Action != "create" && (req.TransactionId < 1 || req.BaseVersion < 1)) {
		return nil, errs.ErrParameterInvalid
	}
	requestHash, err := syncRequestHash(&req)
	if err != nil {
		return nil, errs.ErrParameterInvalid
	}
	operationIdentity, _ := json.Marshal([]string{req.DeviceId, req.OperationId})
	key := sha256.Sum256(operationIdentity)
	uid := c.GetCurrentUid()
	receipt := &models.SyncOperationReceipt{Uid: uid, OperationKey: hex.EncodeToString(key[:]), RequestHash: requestHash}
	db := datastore.Container.UserDataStore.Choose(uid)
	var response *models.SyncPushResponse
	err = db.WithSyncTransaction(c, uid, func(scope *datastore.SyncTransactionScope) error {
		previous, _ := c.Get(datastore.SyncSessionContextKey)
		c.Set(datastore.SyncSessionContextKey, scope)
		defer c.Set(datastore.SyncSessionContextKey, previous)
		old := &models.SyncOperationReceipt{}
		found, err := scope.Session.Where("uid=? AND operation_key=?", uid, receipt.OperationKey).Get(old)
		if err != nil {
			return err
		}
		if found {
			if old.RequestHash != requestHash {
				return errs.ErrRepeatedRequest
			}
			return json.Unmarshal([]byte(old.Response), &response)
		}
		response = &models.SyncPushResponse{Status: "applied", Generation: scope.State.Generation}
		server := &models.SyncRecord{}
		found = false
		if req.TransactionId > 0 {
			found, err = scope.Session.Where("uid=? AND entity=? AND entity_id=?", uid, "transaction", req.TransactionId).Get(server)
			if err != nil {
				return err
			}
			response.Version = server.Version
		}
		if req.Generation != scope.State.Generation {
			response.Status, response.Reason = "conflict", "generation"
		} else if req.Action != "create" && (!found || server.Deleted) {
			response.Status, response.Reason = "conflict", "deleted"
		} else if req.Action != "create" && server.Version != req.BaseVersion {
			response.Status, response.Reason = "conflict", "modified"
			response.Transaction = json.RawMessage(server.Data)
		} else {
			if _, err = scope.Session.Exec("SAVEPOINT native_sync_business"); err != nil {
				return err
			}
			transactionId, apiErr := a.applyTransaction(c, &req, server)
			if apiErr != nil && !errors.Is(apiErr, errs.ErrNothingWillBeUpdated) {
				if apiErr.Category == errs.CATEGORY_SYSTEM || apiErr.HttpStatusCode >= 500 {
					return apiErr
				}
				if _, err = scope.Session.Exec("ROLLBACK TO SAVEPOINT native_sync_business"); err != nil {
					return err
				}
				if _, err = scope.Session.ID(uid).Get(scope.State); err != nil {
					return err
				}
				response.Status = "rejected"
				response.Error = &models.SyncErrorResponse{Code: apiErr.Code(), Message: utils.GetDisplayErrorMessage(apiErr)}
			} else {
				if transactionId == 0 {
					transactionId = req.TransactionId
				}
				current := &models.SyncRecord{}
				found, err = scope.Session.Where("uid=? AND entity=? AND entity_id=?", uid, "transaction", transactionId).Get(current)
				if err != nil {
					return err
				}
				if !found {
					return errs.ErrOperationFailed
				}
				response.Version = current.Version
				if !current.Deleted {
					response.Transaction = json.RawMessage(current.Data)
				}
				// The acknowledgement and the balances it confirms must reach the
				// client together, even if its subsequent journal pull is interrupted.
				var accounts []*models.SyncRecord
				if err = scope.Session.Where("uid=? AND entity=? AND deleted=?", uid, "account", false).Asc("entity_id").Find(&accounts); err != nil {
					return err
				}
				for _, account := range accounts {
					var data map[string]json.RawMessage
					if err = json.Unmarshal([]byte(account.Data), &data); err != nil {
						return err
					}
					data["version"], _ = json.Marshal(strconv.FormatInt(account.Version, 10))
					encoded, err := json.Marshal(data)
					if err != nil {
						return err
					}
					response.Accounts = append(response.Accounts, encoded)
				}
			}
			if _, err = scope.Session.Exec("RELEASE SAVEPOINT native_sync_business"); err != nil {
				return err
			}
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			return err
		}
		receipt.Response = string(encoded)
		_, err = scope.Session.Insert(receipt)
		return err
	})
	if err != nil {
		log.Errorf(c, "[client_sync.PushHandler] synchronization failed for uid:%d, because %s", uid, err.Error())
		return nil, errs.Or(err, errs.ErrOperationFailed)
	}
	return response, nil
}

func (a *ClientSyncApi) applyTransaction(c *core.WebContext, req *models.SyncPushRequest, server *models.SyncRecord) (int64, *errs.Error) {
	var payload map[string]json.RawMessage
	if req.Action != "delete" {
		if json.Unmarshal(req.Data, &payload) != nil || payload == nil {
			return 0, errs.ErrParameterInvalid
		}
		var transactionType models.TransactionType
		if json.Unmarshal(payload["type"], &transactionType) != nil || transactionType < models.TRANSACTION_TYPE_INCOME || transactionType > models.TRANSACTION_TYPE_TRANSFER {
			return 0, errs.ErrTransactionTypeInvalid
		}
	} else {
		payload = make(map[string]json.RawMessage)
		var current models.TransactionInfoResponse
		if json.Unmarshal([]byte(server.Data), &current) != nil || current.Type == models.TRANSACTION_TYPE_MODIFY_BALANCE {
			return 0, errs.ErrTransactionTypeInvalid
		}
	}
	delete(payload, "clientSessionId")
	if req.TransactionId > 0 {
		payload["id"], _ = json.Marshal(strconv.FormatInt(req.TransactionId, 10))
	} else {
		delete(payload, "id")
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return 0, errs.ErrParameterInvalid
	}
	oldBody, oldLength := c.Request.Body, c.Request.ContentLength
	c.Request.Body, c.Request.ContentLength = io.NopCloser(bytes.NewReader(encoded)), int64(len(encoded))
	defer func() { c.Request.Body, c.Request.ContentLength = oldBody, oldLength }()
	var result any
	var apiErr *errs.Error
	switch req.Action {
	case "create":
		result, apiErr = Transactions.TransactionCreateHandler(c)
	case "modify":
		result, apiErr = Transactions.TransactionModifyHandler(c)
	case "delete":
		result, apiErr = Transactions.TransactionDeleteHandler(c)
	}
	if apiErr != nil {
		return 0, apiErr
	}
	if transaction, ok := result.(*models.TransactionInfoResponse); ok {
		return transaction.Id, nil
	}
	return req.TransactionId, nil
}
