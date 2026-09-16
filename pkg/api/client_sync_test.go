package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"github.com/go-playground/validator/v10"
	"github.com/stretchr/testify/require"
	"xorm.io/xorm"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/datastore"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/services"
	"github.com/mayswind/ezbookkeeping/pkg/settings"
	"github.com/mayswind/ezbookkeeping/pkg/storage"
	"github.com/mayswind/ezbookkeeping/pkg/utils"
	"github.com/mayswind/ezbookkeeping/pkg/uuid"
	"github.com/mayswind/ezbookkeeping/pkg/validators"
)

var syncTestUid atomic.Int64
var syncTestUuidOnce sync.Once

type syncFixture struct {
	uid, account, destination, category, transferCategory int64
	db                                                    *datastore.Database
}

// By default these exercise real SQLite. CI additionally supplies an isolated
// MySQL/PostgreSQL database through EZBOOKKEEPING_SYNC_TEST_DB_* variables.
func newSyncFixture(t *testing.T) *syncFixture {
	t.Helper()
	gin.SetMode(gin.TestMode)
	config := &settings.Config{UuidGeneratorType: settings.InternalUuidGeneratorType, UuidServerId: 249, EnableInternalAuth: true, EnableTransactionPictures: true, EnableScheduledTransaction: true, OAuth2StateExpiredTimeDuration: 5 * time.Minute, RootUrl: "https://example.test/books/"}
	dbConfig := &settings.DatabaseConfig{DatabaseType: settings.Sqlite3DbType, DatabasePath: filepath.Join(t.TempDir(), "ledger.db"), MaxOpenConnection: 8, MaxIdleConnection: 2}
	if kind := os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_TYPE"); kind != "" {
		dbConfig.DatabaseType = kind
		dbConfig.DatabaseHost = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_HOST")
		dbConfig.DatabaseUser = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_USER")
		dbConfig.DatabasePassword = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_PASSWORD")
		dbConfig.DatabaseName = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_NAME")
		dbConfig.DatabaseSSLMode = "disable"
	}
	config.DatabaseConfig = dbConfig
	settings.SetCurrentConfig(config)
	require.NoError(t, datastore.InitializeDataStore(config))
	require.NoError(t, datastore.Container.UserDataStore.SyncStructs(new(models.User), new(models.Account), new(models.Transaction), new(models.TransactionCategory), new(models.TransactionTag), new(models.TransactionTagGroup), new(models.TransactionTemplate), new(models.TransactionTagIndex), new(models.TransactionPictureInfo), new(models.SyncLedgerState), new(models.SyncRecord), new(models.SyncChange), new(models.SyncOperationReceipt), new(models.SyncPictureReceipt), new(models.NativeOAuthSession)))
	syncTestUuidOnce.Do(func() {
		require.NoError(t, uuid.InitializeUuidGenerator(config))
		syncTestUid.Store(time.Now().UnixNano()%1000000000000 + 1000000000000)
	})
	require.NoError(t, binding.Validator.Engine().(*validator.Validate).RegisterValidation("validTransactionAmount", validators.ValidTransactionAmount))
	uid := syncTestUid.Add(1)
	f := &syncFixture{uid: uid, account: uid * 10, destination: uid*10 + 1, category: uid*10 + 3, transferCategory: uid*10 + 5, db: datastore.Container.UserDataStore.Choose(uid)}
	closeSyncFixtureEngine(t, f.db)
	require.NoError(t, f.db.DoTransaction(core.NewNullContext(), func(sess *xorm.Session) error {
		_, err := sess.Insert(&models.User{Uid: uid, Username: fmt.Sprintf("sync%d", uid), Email: fmt.Sprintf("sync%d@example.test", uid), DefaultCurrency: "USD", TransactionEditScope: models.TRANSACTION_EDIT_SCOPE_ALL})
		if err != nil {
			return err
		}
		_, err = sess.Insert([]*models.Account{{Uid: uid, AccountId: f.account, Name: "Cash", Type: models.ACCOUNT_TYPE_SINGLE_ACCOUNT, Category: models.ACCOUNT_CATEGORY_CASH, Currency: "USD"}, {Uid: uid, AccountId: f.destination, Name: "Foreign cash", Type: models.ACCOUNT_TYPE_SINGLE_ACCOUNT, Category: models.ACCOUNT_CATEGORY_CASH, Currency: "EUR"}})
		if err != nil {
			return err
		}
		_, err = sess.Insert([]*models.TransactionCategory{{Uid: uid, CategoryId: f.category - 1, Type: models.CATEGORY_TYPE_EXPENSE, Name: "Expense"}, {Uid: uid, CategoryId: f.category, ParentCategoryId: f.category - 1, Type: models.CATEGORY_TYPE_EXPENSE, Name: "Food"}, {Uid: uid, CategoryId: f.transferCategory - 1, Type: models.CATEGORY_TYPE_TRANSFER, Name: "Transfer"}, {Uid: uid, CategoryId: f.transferCategory, ParentCategoryId: f.transferCategory - 1, Type: models.CATEGORY_TYPE_TRANSFER, Name: "Own accounts"}})
		return err
	}))
	return f
}

func closeSyncFixtureEngine(t *testing.T, db *datastore.Database) {
	t.Helper()
	session := db.NewSession(core.NewNullContext())
	engine := session.Engine()
	require.NoError(t, session.Close())
	t.Cleanup(func() { require.NoError(t, engine.Close()) })
}

func (f *syncFixture) context(method, path string, body any) *core.WebContext {
	var encoded []byte
	if body != nil {
		encoded, _ = json.Marshal(body)
	}
	g, _ := gin.CreateTestContext(httptest.NewRecorder())
	g.Request = httptest.NewRequest(method, path, bytes.NewReader(encoded))
	g.Request.Header.Set("Content-Type", "application/json")
	g.Request.Header.Set("X-Timezone-Offset", "480")
	c := &core.WebContext{Context: g}
	c.SetTokenClaims(&core.UserTokenClaims{Uid: f.uid})
	return c
}

func (f *syncFixture) data(amount int64) map[string]any {
	return map[string]any{"type": 3, "categoryId": strconv.FormatInt(f.category, 10), "time": time.Now().Unix(), "utcOffset": 480, "sourceAccountId": strconv.FormatInt(f.account, 10), "sourceAmount": amount, "comment": "offline"}
}

func (f *syncFixture) request(operation string, amount int64) *models.SyncPushRequest {
	data, _ := json.Marshal(f.data(amount))
	return &models.SyncPushRequest{DeviceId: "test-device-00000001", OperationId: operation, Generation: 1, Action: "create", Data: data}
}

func (f *syncFixture) push(t *testing.T, req *models.SyncPushRequest) *models.SyncPushResponse {
	t.Helper()
	value, err := ClientSync.PushHandler(f.context("POST", "/api/v1/sync/push.json", req))
	require.Nil(t, err)
	return value.(*models.SyncPushResponse)
}

func (f *syncFixture) balance(t *testing.T, accountId int64) int64 {
	t.Helper()
	account, err := services.Accounts.GetAccountByAccountId(core.NewNullContext(), f.uid, accountId)
	require.NoError(t, err)
	return account.Balance
}

func TestClientSyncDurableRetryConflictAndClear(t *testing.T) {
	f := newSyncFixture(t)
	req := f.request("create-operation-0001", 125)
	first := f.push(t, req)
	require.Equal(t, "applied", first.Status)
	require.Equal(t, int64(1), first.Version)
	require.Equal(t, int64(-125), f.balance(t, f.account))
	require.Len(t, first.Accounts, 2)
	var acknowledgedAccount map[string]any
	require.NoError(t, json.Unmarshal(first.Accounts[0], &acknowledgedAccount))
	require.Equal(t, strconv.FormatInt(f.account, 10), acknowledgedAccount["id"])
	require.Equal(t, "-125", acknowledgedAccount["balance"])
	require.NotEmpty(t, acknowledgedAccount["version"])
	// Reopen the database: receipts are recovered from durable storage, not API state.
	require.NoError(t, datastore.InitializeDataStore(settings.Container.GetCurrentConfig()))
	f.db = datastore.Container.UserDataStore.Choose(f.uid)
	closeSyncFixtureEngine(t, f.db)
	api := &ClientSyncApi{}
	replay, err := api.PushHandler(f.context("POST", "/api/v1/sync/push.json", req))
	require.Nil(t, err)
	require.Equal(t, first, replay)
	require.Equal(t, int64(-125), f.balance(t, f.account))
	changed := *req
	changed.Data, _ = json.Marshal(f.data(126))
	_, err = api.PushHandler(f.context("POST", "/api/v1/sync/push.json", &changed))
	require.NotNil(t, err)
	var transaction models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal(first.Transaction, &transaction))
	webData := f.data(250)
	webData["id"] = strconv.FormatInt(transaction.Id, 10)
	_, err = Transactions.TransactionModifyHandler(f.context("POST", "/api/v1/transactions/modify.json", webData))
	require.Nil(t, err)
	modify := f.request("modify-operation-0001", 375)
	modify.Action, modify.TransactionId, modify.BaseVersion = "modify", transaction.Id, 1
	conflict := f.push(t, modify)
	require.Equal(t, "conflict", conflict.Status)
	require.Equal(t, "modified", conflict.Reason)
	require.Equal(t, int64(2), conflict.Version)
	require.Equal(t, int64(-250), f.balance(t, f.account))
	modify.OperationId, modify.BaseVersion = "modify-operation-0002", conflict.Version
	require.Equal(t, "applied", f.push(t, modify).Status)
	require.Equal(t, int64(-375), f.balance(t, f.account))
	require.NoError(t, services.Transactions.DeleteAllTransactions(core.NewNullContext(), f.uid, false))
	afterClear := f.push(t, f.request("create-operation-0002", 1))
	require.Equal(t, "generation", afterClear.Reason)
	require.Equal(t, int64(2), afterClear.Generation)
	require.Equal(t, int64(0), f.balance(t, f.account))
}

func TestClientSyncGeoLocationNameRoundTrip(t *testing.T) {
	f := newSyncFixture(t)
	data := f.data(125)
	data["geoLocation"] = map[string]any{"latitude": 39.9, "longitude": 116.3}
	data["geoLocationName"] = "Office"
	encoded, err := json.Marshal(data)
	require.NoError(t, err)

	response := f.push(t, &models.SyncPushRequest{
		DeviceId:    "test-device-00000001",
		OperationId: "location-operation-0001",
		Generation:  1,
		Action:      "create",
		Data:        encoded,
	})

	var transaction models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal(response.Transaction, &transaction))
	require.Equal(t, "Office", transaction.GeoLocationName)
	require.Equal(t, 39.9, transaction.GeoLocation.Latitude)
	require.Equal(t, 116.3, transaction.GeoLocation.Longitude)
}

func TestClientSyncAtomicTransferAndRollback(t *testing.T) {
	f := newSyncFixture(t)
	request := f.request("transfer-operation-1", 1200)
	data := f.data(1200)
	data["type"], data["categoryId"], data["destinationAccountId"], data["destinationAmount"] = 4, strconv.FormatInt(f.transferCategory, 10), strconv.FormatInt(f.destination, 10), 1100
	request.Data, _ = json.Marshal(data)
	ctx := f.context("POST", "/api/v1/sync/push.json", request)
	err := f.db.WithSyncTransaction(ctx, f.uid, func(scope *datastore.SyncTransactionScope) error {
		ctx.Set(datastore.SyncSessionContextKey, scope)
		defer ctx.Set(datastore.SyncSessionContextKey, nil)
		response, apiErr := ClientSync.PushHandler(ctx)
		require.Nil(t, apiErr)
		require.Equal(t, "applied", response.(*models.SyncPushResponse).Status)
		return errors.New("simulate failure before database commit")
	})
	require.Error(t, err)
	require.Equal(t, int64(0), f.balance(t, f.account))
	require.Equal(t, int64(0), f.balance(t, f.destination))
	result := f.push(t, request)
	require.Equal(t, "applied", result.Status)
	require.Equal(t, int64(-1200), f.balance(t, f.account))
	require.Equal(t, int64(1100), f.balance(t, f.destination))
	require.Len(t, result.Accounts, 2)
	var acknowledgedDestination map[string]any
	require.NoError(t, json.Unmarshal(result.Accounts[1], &acknowledgedDestination))
	require.Equal(t, "1100", acknowledgedDestination["balance"])
	count, err := f.db.NewSession(core.NewNullContext()).Where("uid=? AND deleted=?", f.uid, false).Count(&models.Transaction{})
	require.NoError(t, err)
	require.Equal(t, int64(2), count)
	count, err = f.db.NewSession(core.NewNullContext()).Where("uid=? AND entity=?", f.uid, "transaction").Count(&models.SyncRecord{})
	require.NoError(t, err)
	require.Equal(t, int64(1), count)
	var transaction models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal(result.Transaction, &transaction))
	deleteReq := &models.SyncPushRequest{DeviceId: request.DeviceId, OperationId: "delete-operation-001", Generation: 1, BaseVersion: 1, Action: "delete", TransactionId: transaction.Id}
	require.Equal(t, "applied", f.push(t, deleteReq).Status)
	require.Equal(t, int64(0), f.balance(t, f.account))
	require.Equal(t, int64(0), f.balance(t, f.destination))
	require.Equal(t, "applied", f.push(t, deleteReq).Status)
	deleteReq.OperationId = "delete-operation-002"
	require.Equal(t, "deleted", f.push(t, deleteReq).Reason)
}

func TestClientSyncSnapshotPagingAndSameSecondChanges(t *testing.T) {
	f := newSyncFixture(t)
	created := f.push(t, f.request("snapshot-operation-1", 10))
	var transaction models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal(created.Transaction, &transaction))
	first, apiErr := ClientSync.SnapshotHandler(f.context("GET", "/api/v1/sync/snapshot.json?count=1", nil))
	require.Nil(t, apiErr)
	page := first.(map[string]any)
	start := page["cursor"].(string)
	require.Equal(t, true, page["hasMore"])
	// Mutations after the starting cursor must be replayed even with identical
	// wall-clock timestamps; journal ordering uses locked cursors, not seconds.
	for n := int64(20); n <= 30; n += 10 {
		req := f.request(fmt.Sprintf("snapshot-modify-%03d", n), n)
		req.Action, req.TransactionId, req.BaseVersion = "modify", transaction.Id, n/10-1
		require.Equal(t, "applied", f.push(t, req).Status)
	}
	for page["hasMore"] == true {
		next := page["nextPage"].(string)
		value, err := ClientSync.SnapshotHandler(f.context("GET", "/api/v1/sync/snapshot.json?count=1&page_token="+url.QueryEscape(next), nil))
		require.Nil(t, err)
		page = value.(map[string]any)
		require.Equal(t, start, page["cursor"])
	}
	changes, apiErr := ClientSync.ChangesHandler(f.context("GET", "/api/v1/sync/changes.json?generation=1&cursor="+start, nil))
	require.Nil(t, apiErr)
	versions := []int64{}
	for _, change := range changes.(map[string]any)["changes"].([]syncChangeResponse) {
		if change.Entity == "transaction" {
			versions = append(versions, change.Version)
		}
	}
	require.Equal(t, []int64{2, 3}, versions)
	other := *f
	other.uid++
	_, apiErr = ClientSync.SnapshotHandler(other.context("GET", "/api/v1/sync/snapshot.json?page_token="+url.QueryEscape(first.(map[string]any)["nextPage"].(string)), nil))
	require.NotNil(t, apiErr)
}

func TestNativeOAuthVerifierAndOneTimeExchange(t *testing.T) {
	f := newSyncFixture(t)
	verifier := strings.Repeat("x", 43)
	challenge := sha256.Sum256([]byte(verifier))
	sessionId := fmt.Sprintf("native-session-%d", f.uid)
	session := &models.NativeOAuthSession{SessionId: sessionId, CodeChallenge: base64.RawURLEncoding.EncodeToString(challenge[:]), ExpiresUnixTime: time.Now().Add(time.Minute).Unix()}
	require.NoError(t, f.db.DoTransaction(core.NewNullContext(), func(sess *xorm.Session) error { _, err := sess.Insert(session); return err }))
	ctx := f.context("GET", "/oauth2/callback", nil)
	ctx.Set(nativeOAuthContextKey, sessionId)
	redirect, apiErr := OAuth2Authentications.redirectToNativeCallback(ctx, map[string]any{"token": "short-lived-callback-token", "provider": "oidc"})
	require.Nil(t, apiErr)
	require.NotContains(t, redirect, "short-lived-callback-token")
	parsed, err := url.Parse(redirect)
	require.NoError(t, err)
	code := parsed.Query().Get("code")
	_, apiErr = OAuth2Authentications.NativeExchangeHandler(f.context("POST", "/exchange", map[string]any{"code": code, "codeVerifier": strings.Repeat("y", 43)}))
	require.NotNil(t, apiErr)
	value, apiErr := OAuth2Authentications.NativeExchangeHandler(f.context("POST", "/exchange", map[string]any{"code": code, "codeVerifier": verifier}))
	require.Nil(t, apiErr)
	require.Contains(t, string(value.(json.RawMessage)), "short-lived-callback-token")
	_, apiErr = OAuth2Authentications.NativeExchangeHandler(f.context("POST", "/exchange", map[string]any{"code": code, "codeVerifier": verifier}))
	require.NotNil(t, apiErr)
}

func TestClientSyncSimultaneousOperations(t *testing.T) {
	f := newSyncFixture(t)
	_, apiErr := ClientSync.SnapshotHandler(f.context("GET", "/snapshot", nil))
	require.Nil(t, apiErr)
	same := f.request("concurrent-same-0001", 100)
	requests := []*models.SyncPushRequest{same, same, f.request("concurrent-other-001", 50), f.request("concurrent-other-002", 50)}
	results := make([]*models.SyncPushResponse, len(requests))
	errorsByRequest := make([]error, len(requests))
	var workers sync.WaitGroup
	for index, request := range requests {
		workers.Add(1)
		go func(index int, request *models.SyncPushRequest) {
			defer workers.Done()
			for attempt := 0; attempt < 50; attempt++ {
				value, err := ClientSync.PushHandler(f.context("POST", "/push", request))
				if err == nil {
					results[index] = value.(*models.SyncPushResponse)
					errorsByRequest[index] = nil
					return
				}
				errorsByRequest[index] = err
				// SQLite can report SQLITE_LOCKED while another connection holds
				// the write lock. Retrying the same durable operation is safe.
				time.Sleep(10 * time.Millisecond)
			}
		}(index, request)
	}
	workers.Wait()
	for index, err := range errorsByRequest {
		require.NoError(t, err)
		require.Equal(t, "applied", results[index].Status)
	}
	require.Equal(t, results[0], results[1])
	require.Equal(t, int64(-200), f.balance(t, f.account))
	count, err := f.db.NewSession(core.NewNullContext()).Where("uid=?", f.uid).Count(&models.SyncOperationReceipt{})
	require.NoError(t, err)
	require.Equal(t, int64(3), count)
}

func TestClientSyncIncomingTransferAndMetadataPermissions(t *testing.T) {
	f := newSyncFixture(t)
	ctx := core.NewNullContext()
	transaction := &models.Transaction{Uid: f.uid, Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, AccountId: f.account, RelatedAccountId: f.destination, Amount: 1200, RelatedAccountAmount: 1100, CategoryId: f.transferCategory, TransactionTime: utils.GetMinTransactionTimeFromUnixTime(time.Now().Unix())}
	require.NoError(t, services.Transactions.CreateTransaction(ctx, transaction, nil, nil))
	var canonical models.SyncRecord
	found, err := f.db.NewSession(ctx).Where("uid=? AND entity=? AND entity_id=?", f.uid, "transaction", transaction.TransactionId).Get(&canonical)
	require.NoError(t, err)
	require.True(t, found)
	require.Equal(t, int64(1), canonical.Version)
	require.NoError(t, services.Accounts.HideAccount(ctx, f.uid, []int64{f.account}, true))
	result, apiErr := ClientSync.SnapshotHandler(f.context("GET", "/snapshot", nil))
	require.Nil(t, apiErr)
	items := result.(map[string]any)["transactions"].([]json.RawMessage)
	require.Len(t, items, 1)
	var public models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal(items[0], &public))
	require.False(t, public.Editable)
	require.NoError(t, services.Accounts.HideAccount(ctx, f.uid, []int64{f.account}, false))
	// Both the existing Web API and service reject the incoming half. The
	// service rejects after issuing writes; its transaction must roll them back.
	_, apiErr = Transactions.TransactionDeleteHandler(f.context("POST", "/delete", map[string]string{"id": strconv.FormatInt(transaction.RelatedId, 10)}))
	require.NotNil(t, apiErr)
	require.ErrorIs(t, services.Transactions.DeleteTransaction(ctx, f.uid, transaction.RelatedId), errs.ErrTransactionTypeInvalid)
	require.Equal(t, int64(-1200), f.balance(t, f.account))
	require.Equal(t, int64(1100), f.balance(t, f.destination))
	_, apiErr = Transactions.TransactionDeleteHandler(f.context("POST", "/delete", map[string]string{"id": strconv.FormatInt(transaction.TransactionId, 10)}))
	require.Nil(t, apiErr)
	canonical = models.SyncRecord{}
	_, err = f.db.NewSession(ctx).Where("uid=? AND entity=? AND entity_id=?", f.uid, "transaction", transaction.TransactionId).Get(&canonical)
	require.NoError(t, err)
	require.True(t, canonical.Deleted)
	require.Equal(t, int64(2), canonical.Version)
	require.Equal(t, int64(0), f.balance(t, f.account))
	require.Equal(t, int64(0), f.balance(t, f.destination))
}

func TestClientSyncBalanceAdjustmentDeltaProjection(t *testing.T) {
	f := newSyncFixture(t)
	ctx := core.NewNullContext()
	now := time.Now().Unix()
	// Preserve a nonzero account baseline so the absolute amount and the
	// adjustment's effect differ, as they can in existing stored ledgers.
	require.NoError(t, f.db.DoLedgerTransaction(ctx, f.uid, nil, func(sess *xorm.Session) error {
		_, err := sess.ID(f.account).Cols("balance").Update(&models.Account{Balance: -100})
		return err
	}))
	adjustment := &models.Transaction{Uid: f.uid, Type: models.TRANSACTION_DB_TYPE_MODIFY_BALANCE, AccountId: f.account, Amount: 500, TransactionTime: utils.GetMinTransactionTimeFromUnixTime(now)}
	require.NoError(t, services.Transactions.CreateTransaction(ctx, adjustment, nil, nil))
	require.Equal(t, int64(500), f.balance(t, f.account))
	snapshot, apiErr := ClientSync.SnapshotHandler(f.context("GET", "/snapshot", nil))
	require.Nil(t, apiErr)
	items := snapshot.(map[string]any)["transactions"].([]json.RawMessage)
	require.Len(t, items, 1)
	var public models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal(items[0], &public))
	require.Equal(t, int64(500), public.SourceAmount)
	require.NotNil(t, public.BalanceDelta)
	require.Equal(t, int64(600), *public.BalanceDelta)
	web, err := json.Marshal(adjustment.ToTransactionInfoResponse(nil, true))
	require.NoError(t, err)
	require.NotContains(t, string(web), "balanceDelta")
	adjustment.Amount = 700
	require.NoError(t, services.Transactions.ModifyTransaction(ctx, adjustment, false, 0, nil, nil, nil, nil))
	require.Equal(t, int64(700), f.balance(t, f.account))
	changes, apiErr := ClientSync.ChangesHandler(f.context("GET", fmt.Sprintf("/changes?generation=%s&cursor=%s", snapshot.(map[string]any)["generation"], snapshot.(map[string]any)["cursor"]), nil))
	require.Nil(t, apiErr)
	found := false
	for _, change := range changes.(map[string]any)["changes"].([]syncChangeResponse) {
		if change.Entity != "transaction" || change.Id != adjustment.TransactionId {
			continue
		}
		found = true
		require.NoError(t, json.Unmarshal(change.Data, &public))
		require.Equal(t, int64(700), public.SourceAmount)
		require.NotNil(t, public.BalanceDelta)
		require.Equal(t, int64(800), *public.BalanceDelta)
	}
	require.True(t, found)
}

func TestClientSyncImportedScheduledAndTagChanges(t *testing.T) {
	f := newSyncFixture(t)
	ctx := core.NewNullContext()
	transaction := &models.Transaction{Uid: f.uid, Type: models.TRANSACTION_DB_TYPE_EXPENSE, AccountId: f.account, Amount: 75, CategoryId: f.category, TransactionTime: utils.GetMinTransactionTimeFromUnixTime(time.Now().Unix())}
	require.NoError(t, services.Transactions.BatchCreateTransactions(ctx, f.uid, []*models.Transaction{transaction}, nil, nil))
	tag := &models.TransactionTag{Uid: f.uid, Name: "Imported"}
	require.NoError(t, services.TransactionTags.CreateTag(ctx, tag))
	require.NoError(t, services.Transactions.BatchAddTagsToTransactions(ctx, f.uid, []*models.Transaction{transaction}, map[int64][]int64{transaction.TransactionId: {tag.TagId}}))
	var record models.SyncRecord
	_, err := f.db.NewSession(ctx).Where("uid=? AND entity=? AND entity_id=?", f.uid, "transaction", transaction.TransactionId).Get(&record)
	require.NoError(t, err)
	require.Equal(t, int64(2), record.Version)
	require.Contains(t, record.Data, strconv.FormatInt(tag.TagId, 10))
	require.NoError(t, services.Transactions.BatchClearAllTagsFromTransactions(ctx, f.uid, []int64{transaction.TransactionId}))
	record = models.SyncRecord{}
	_, err = f.db.NewSession(ctx).Where("uid=? AND entity=? AND entity_id=?", f.uid, "transaction", transaction.TransactionId).Get(&record)
	require.NoError(t, err)
	require.Equal(t, int64(3), record.Version)
	now := time.Now().UTC()
	template := &models.TransactionTemplate{Uid: f.uid, TemplateType: models.TRANSACTION_TEMPLATE_TYPE_SCHEDULE, Name: "Scheduled", Type: models.TRANSACTION_TYPE_EXPENSE, AccountId: f.account, CategoryId: f.category, Amount: 25, ScheduledFrequencyType: models.TRANSACTION_SCHEDULE_FREQUENCY_TYPE_DAILY, ScheduledFrequency: "1", ScheduledAt: int16(now.Hour()*60 + now.Minute())}
	require.NoError(t, services.TransactionTemplates.CreateTemplate(ctx, template))
	require.NoError(t, services.Transactions.CreateScheduledTransactions(ctx, now.Unix(), time.Minute))
	count, err := f.db.NewSession(ctx).Where("uid=? AND scheduled_created=?", f.uid, true).Count(&models.Transaction{})
	require.NoError(t, err)
	require.Equal(t, int64(1), count)
	count, err = f.db.NewSession(ctx).Where("uid=? AND entity=?", f.uid, "transaction").Count(&models.SyncRecord{})
	require.NoError(t, err)
	require.Equal(t, int64(2), count)
	require.Equal(t, int64(-100), f.balance(t, f.account))
	// Prevent later matrix tests from executing this user's schedule again.
	require.NoError(t, services.TransactionTemplates.DeleteTemplate(ctx, f.uid, template.TemplateId))
}

func TestClientSyncPictureUploadSurvivesRetry(t *testing.T) {
	f := newSyncFixture(t)
	config := settings.Container.GetCurrentConfig()
	config.StorageType, config.LocalFileSystemPath = settings.LocalFileSystemObjectStorageType, t.TempDir()
	config.MaxTransactionPictureFileSize = 1024
	require.NoError(t, storage.InitializeStorageContainer(config))
	request := func(content string) *core.WebContext {
		var buffer bytes.Buffer
		form := multipart.NewWriter(&buffer)
		file, err := form.CreateFormFile("picture", "receipt.png")
		require.NoError(t, err)
		_, err = file.Write([]byte(content))
		require.NoError(t, err)
		require.NoError(t, form.WriteField("upload_id", "persistent-picture-001"))
		require.NoError(t, form.Close())
		ctx := f.context("POST", "/upload", nil)
		ctx.Request = httptest.NewRequest("POST", "/upload", &buffer)
		ctx.Request.Header.Set("Content-Type", form.FormDataContentType())
		return ctx
	}
	first, apiErr := TransactionPictures.TransactionPictureUploadHandler(request("image bytes"))
	require.Nil(t, apiErr)
	require.NoError(t, datastore.InitializeDataStore(config))
	second, apiErr := TransactionPictures.TransactionPictureUploadHandler(request("image bytes"))
	require.Nil(t, apiErr)
	require.Equal(t, first, second)
	_, apiErr = TransactionPictures.TransactionPictureUploadHandler(request("different bytes"))
	require.NotNil(t, apiErr)
	count, err := f.db.NewSession(core.NewNullContext()).Where("uid=?", f.uid).Count(&models.TransactionPictureInfo{})
	require.NoError(t, err)
	require.Equal(t, int64(1), count)
}
