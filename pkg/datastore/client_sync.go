package datastore

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"xorm.io/builder"
	"xorm.io/xorm"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

const SyncSessionContextKey = "ezbookkeeping.sync.transaction"

// SyncTransactionScope lets native push reuse all existing API validation and
// service queries within the transaction which owns the ledger lock and receipt.
type SyncTransactionScope struct {
	Database *Database
	Session  *xorm.Session
	State    *models.SyncLedgerState
}

func (db *Database) syncScope(c core.Context) *SyncTransactionScope {
	if c == nil {
		return nil
	}
	scope, _ := c.Value(SyncSessionContextKey).(*SyncTransactionScope)
	if scope != nil && scope.Database == db {
		return scope
	}
	return nil
}

// WithSyncTransaction serializes a user's writes across processes using a row
// update, supported by SQLite, MySQL and PostgreSQL. The lock is held to commit.
func (db *Database) WithSyncTransaction(c core.Context, uid int64, fn func(*SyncTransactionScope) error) error {
	if uid <= 0 {
		return errs.ErrUserIdInvalid
	}
	if scope := db.syncScope(c); scope != nil {
		if scope.State.Uid != uid {
			return errs.ErrUserIdInvalid
		}
		return fn(scope)
	}
	return db.DoTransaction(c, func(sess *xorm.Session) error {
		state, err := db.lockSyncLedger(sess, uid)
		if err != nil {
			return err
		}
		if !state.Initialized {
			if err = db.refreshSyncRecords(sess, state, nil); err != nil {
				return err
			}
			state.Initialized = true
			if _, err = sess.ID(uid).Cols("initialized").Update(state); err != nil {
				return err
			}
		}
		return fn(&SyncTransactionScope{Database: db, Session: sess, State: state})
	})
}

func (db *Database) lockSyncLedger(sess *xorm.Session, uid int64) (*models.SyncLedgerState, error) {
	rows, err := sess.ID(uid).SetExpr("guard", "guard+1").Update(&models.SyncLedgerState{})
	if err != nil {
		return nil, err
	}
	if rows == 0 {
		// Concurrent first writes may race on this insert. The loser rolls back
		// and can retry the original operation; no business effect has run yet.
		if _, err = sess.Insert(&models.SyncLedgerState{Uid: uid, Generation: 1, Guard: 1}); err != nil {
			return nil, err
		}
	}
	state := &models.SyncLedgerState{}
	_, err = sess.ID(uid).Get(state)
	return state, err
}

// DoLedgerTransaction journals every affected public record in the same commit.
// A nil ID slice requests a full scan for bulk operations; an empty slice only
// refreshes metadata. Ordinary create/edit/delete pass their transaction IDs.
func (db *Database) DoLedgerTransaction(c core.Context, uid int64, transactionIds []int64, fn func(*xorm.Session) error) error {
	return db.WithSyncTransaction(c, uid, func(scope *SyncTransactionScope) error {
		if err := fn(scope.Session); err != nil {
			return err
		}
		return db.refreshSyncRecords(scope.Session, scope.State, transactionIds)
	})
}

// ResetSyncGeneration prevents old offline creates from undoing a ledger clear.
func (db *Database) ResetSyncGeneration(c core.Context, sess *xorm.Session, uid int64) error {
	_, err := sess.ID(uid).SetExpr("generation", "generation+1").Update(&models.SyncLedgerState{})
	if err == nil {
		if scope := db.syncScope(c); scope != nil {
			scope.State.Generation++
		}
	}
	return err
}

func (db *Database) refreshSyncRecords(sess *xorm.Session, state *models.SyncLedgerState, transactionIds []int64) error {
	uid := state.Uid
	var records []*models.SyncRecord
	add := func(entity string, id int64, deleted bool, value any) error {
		data := "null"
		if !deleted {
			encoded, err := json.Marshal(value)
			if err != nil {
				return err
			}
			data = string(encoded)
		}
		records = append(records, &models.SyncRecord{Uid: uid, Entity: entity, EntityId: id, Deleted: deleted, Data: data})
		return nil
	}
	var accounts []*models.Account
	if err := sess.Where("uid=?", uid).Find(&accounts); err != nil {
		return err
	}
	for _, value := range accounts {
		if err := add("account", value.AccountId, value.Deleted, value.ToAccountInfoResponse()); err != nil {
			return err
		}
	}
	var categories []*models.TransactionCategory
	if err := sess.Where("uid=?", uid).Find(&categories); err != nil {
		return err
	}
	for _, value := range categories {
		if err := add("category", value.CategoryId, value.Deleted, value.ToTransactionCategoryInfoResponse()); err != nil {
			return err
		}
	}
	var tags []*models.TransactionTag
	if err := sess.Where("uid=?", uid).Find(&tags); err != nil {
		return err
	}
	for _, value := range tags {
		if err := add("tag", value.TagId, value.Deleted, value.ToTransactionTagInfoResponse()); err != nil {
			return err
		}
	}
	var groups []*models.TransactionTagGroup
	if err := sess.Where("uid=?", uid).Find(&groups); err != nil {
		return err
	}
	for _, value := range groups {
		if err := add("tagGroup", value.TagGroupId, value.Deleted, value.ToTransactionTagGroupInfoResponse()); err != nil {
			return err
		}
	}
	var templates []*models.TransactionTemplate
	if err := sess.Where("uid=?", uid).Find(&templates); err != nil {
		return err
	}
	_, serverOffset := time.Now().Zone()
	for _, value := range templates {
		if err := add("template", value.TemplateId, value.Deleted, value.ToTransactionTemplateInfoResponse(int16(serverOffset/60))); err != nil {
			return err
		}
	}
	if transactionIds == nil || len(transactionIds) > 0 {
		var transactions []*models.Transaction
		query := sess.Where("uid=?", uid)
		if transactionIds != nil {
			query = query.And(builder.Or(builder.In("transaction_id", transactionIds), builder.In("related_id", transactionIds)))
		}
		if err := query.Find(&transactions); err != nil {
			return err
		}
		ids := make([]int64, 0, len(transactions))
		for _, transaction := range transactions {
			ids = append(ids, transaction.TransactionId)
		}
		var indexes []*models.TransactionTagIndex
		var pictures []*models.TransactionPictureInfo
		if len(ids) > 0 {
			// Full scans avoid driver parameter limits on large imports/snapshots.
			query = sess.Where("uid=? AND deleted=?", uid, false)
			if transactionIds != nil {
				query = query.In("transaction_id", ids)
			}
			if err := query.OrderBy("tag_index_id asc").Find(&indexes); err != nil {
				return err
			}
			query = sess.Where("uid=? AND deleted=?", uid, false)
			if transactionIds != nil {
				query = query.In("transaction_id", ids)
			}
			if err := query.OrderBy("picture_id asc").Find(&pictures); err != nil {
				return err
			}
		}
		tagIds := make(map[int64][]int64)
		for _, index := range indexes {
			tagIds[index.TransactionId] = append(tagIds[index.TransactionId], index.TagId)
		}
		pictureMap := make(map[int64]models.TransactionPictureInfoBasicResponseSlice)
		for _, picture := range pictures {
			url := fmt.Sprintf("pictures/%d.%s", picture.PictureId, picture.PictureExtension)
			pictureMap[picture.TransactionId] = append(pictureMap[picture.TransactionId], picture.ToTransactionPictureInfoBasicResponse(url))
		}
		for _, value := range transactions {
			if value.Type == models.TRANSACTION_DB_TYPE_TRANSFER_IN {
				// A bulk move may change which physical half is canonical. Emit a
				// tombstone if this ID previously represented an outgoing record.
				if err := add("transaction", value.TransactionId, true, nil); err != nil {
					return err
				}
				continue
			}
			response := value.ToTransactionInfoResponse(tagIds[value.TransactionId], true)
			if value.Type == models.TRANSACTION_DB_TYPE_MODIFY_BALANCE {
				response.BalanceDelta = &value.RelatedAccountAmount
			}
			response.Pictures = pictureMap[value.TransactionId]
			if err := add("transaction", value.TransactionId, value.Deleted, response); err != nil {
				return err
			}
		}
	}
	// Stable order makes multi-entity commits reproducible and snapshots portable.
	sort.Slice(records, func(i, j int) bool {
		if records[i].Entity != records[j].Entity {
			return records[i].Entity < records[j].Entity
		}
		return records[i].EntityId < records[j].EntityId
	})
	for _, record := range records {
		old := &models.SyncRecord{}
		found, err := sess.Where("uid=? AND entity=? AND entity_id=?", uid, record.Entity, record.EntityId).Get(old)
		if err != nil {
			return err
		}
		if found && old.Deleted == record.Deleted && old.Data == record.Data {
			continue
		}
		if !found && record.Deleted {
			continue
		}
		record.Version = old.Version + 1
		if found {
			_, err = sess.Where("uid=? AND entity=? AND entity_id=?", uid, record.Entity, record.EntityId).Cols("version", "deleted", "data").Update(record)
		} else {
			_, err = sess.Insert(record)
		}
		if err != nil {
			return err
		}
		state.Cursor++
		_, err = sess.Insert(&models.SyncChange{Uid: uid, Cursor: state.Cursor, Entity: record.Entity, EntityId: record.EntityId, Version: record.Version, Deleted: record.Deleted, Data: record.Data})
		if err != nil {
			return err
		}
	}
	_, err := sess.ID(uid).Cols("cursor").Update(state)
	return err
}
