package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gin-gonic/gin/binding"
	"github.com/go-playground/validator/v10"
	"github.com/stretchr/testify/require"
	"xorm.io/xorm"

	"github.com/mayswind/ezbookkeeping/pkg/api"
	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/datastore"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/settings"
	"github.com/mayswind/ezbookkeeping/pkg/utils"
	"github.com/mayswind/ezbookkeeping/pkg/uuid"
	"github.com/mayswind/ezbookkeeping/pkg/validators"
)

// External engines require a separate empty database. The ordinary sync_test
// database may already contain tables and cannot prove a pre-sync upgrade.
func TestDatabaseUpgradePopulatedPreSyncLedger(t *testing.T) {
	config := &settings.Config{UuidGeneratorType: settings.InternalUuidGeneratorType, UuidServerId: 248, EnableInternalAuth: true, EnableTransactionPictures: true, RootUrl: "https://example.test/books/"}
	dbConfig := &settings.DatabaseConfig{DatabaseType: settings.Sqlite3DbType, DatabasePath: filepath.Join(t.TempDir(), "upgrade.db"), MaxOpenConnection: 8, MaxIdleConnection: 2}
	if kind := os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_TYPE"); kind != "" {
		name := os.Getenv("EZBOOKKEEPING_UPGRADE_TEST_DB_NAME")
		if name == "" {
			t.Skip("set EZBOOKKEEPING_UPGRADE_TEST_DB_NAME to an empty upgrade_test_* database")
		}
		require.True(t, strings.HasPrefix(name, "upgrade_test_"), "upgrade tests require a dedicated database")
		dbConfig.DatabaseType, dbConfig.DatabaseName = kind, name
		dbConfig.DatabaseHost = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_HOST")
		dbConfig.DatabaseUser = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_USER")
		dbConfig.DatabasePassword = os.Getenv("EZBOOKKEEPING_SYNC_TEST_DB_PASSWORD")
		dbConfig.DatabaseSSLMode = "disable"
	}
	config.DatabaseConfig = dbConfig
	settings.SetCurrentConfig(config)
	gin.SetMode(gin.TestMode)
	require.NoError(t, binding.Validator.Engine().(*validator.Validate).RegisterValidation("validTransactionAmount", validators.ValidTransactionAmount))
	require.NoError(t, binding.Validator.Engine().(*validator.Validate).RegisterValidation("validCurrency", validators.ValidCurrency))
	require.NoError(t, uuid.InitializeUuidGenerator(config))
	open := func() *xorm.Engine {
		require.NoError(t, datastore.InitializeDataStore(config))
		session := datastore.Container.UserDataStore.Choose(1).NewSession(core.NewNullContext())
		engine := session.Engine()
		require.NoError(t, session.Close())
		t.Cleanup(func() { require.NoError(t, engine.Close()) })
		return engine
	}
	engine := open()
	tables, err := engine.DBMetas()
	require.NoError(t, err)
	require.Empty(t, tables, "refusing to seed an existing database")
	// These are the existing database-update models, before sync was added.
	// Their persisted fields have not changed in the native-client migration.
	require.NoError(t, datastore.Container.UserDataStore.SyncStructs(new(models.User), new(models.TwoFactor), new(models.TwoFactorRecoveryCode), new(models.TokenRecord), new(models.Account), new(models.Transaction), new(models.TransactionCategory), new(models.TransactionTagGroup), new(models.TransactionTag), new(models.TransactionTagIndex), new(models.TransactionTemplate), new(models.TransactionPictureInfo), new(models.UserCustomIcon), new(models.UserCustomExchangeRate), new(models.ExchangeRateHistory), new(models.UserApplicationCloudSetting), new(models.UserExternalAuth), new(models.InsightsExplorer)))
	syncModels := []any{new(models.SyncLedgerState), new(models.SyncRecord), new(models.SyncChange), new(models.SyncOperationReceipt), new(models.SyncPictureReceipt), new(models.NativeOAuthSession)}
	for _, model := range syncModels {
		exists, err := engine.IsTableExist(model)
		require.NoError(t, err)
		require.False(t, exists)
	}

	now := time.Now().Unix()
	for _, uid := range []int64{101, 102} {
		base := uid * 100
		_, err := engine.Insert(&models.User{Uid: uid, Username: fmt.Sprintf("upgrade%d", uid), Email: fmt.Sprintf("upgrade%d@example.test", uid), DefaultCurrency: "USD", TransactionEditScope: models.TRANSACTION_EDIT_SCOPE_ALL})
		require.NoError(t, err)
		_, err = engine.Insert([]*models.Account{
			{Uid: uid, AccountId: base + 1, Name: "Existing cash", Type: models.ACCOUNT_TYPE_SINGLE_ACCOUNT, Category: models.ACCOUNT_CATEGORY_CASH, Currency: "USD", Balance: 1500},
			{Uid: uid, AccountId: base + 2, Name: "Existing foreign cash", Type: models.ACCOUNT_TYPE_SINGLE_ACCOUNT, Category: models.ACCOUNT_CATEGORY_CASH, Currency: "EUR", Balance: 300},
		})
		require.NoError(t, err)
		for index, kind := range []models.TransactionCategoryType{models.CATEGORY_TYPE_INCOME, models.CATEGORY_TYPE_EXPENSE, models.CATEGORY_TYPE_TRANSFER} {
			id := base + 10 + int64(index)*2
			_, err = engine.Insert([]*models.TransactionCategory{{Uid: uid, CategoryId: id, Type: kind, Name: "Existing category"}, {Uid: uid, CategoryId: id + 1, ParentCategoryId: id, Type: kind, Name: "Existing child"}})
			require.NoError(t, err)
		}
		transactionTime := utils.GetMinTransactionTimeFromUnixTime(now)
		_, err = engine.Insert([]*models.Transaction{
			{Uid: uid, TransactionId: base + 20, Type: models.TRANSACTION_DB_TYPE_INCOME, AccountId: base + 1, CategoryId: base + 11, Amount: 2000, TransactionTime: transactionTime, TimezoneUtcOffset: 480, Comment: "Existing income"},
			{Uid: uid, TransactionId: base + 21, Type: models.TRANSACTION_DB_TYPE_EXPENSE, AccountId: base + 1, CategoryId: base + 13, Amount: 100, TransactionTime: transactionTime + 1, TimezoneUtcOffset: 480, Comment: "Existing expense"},
			{Uid: uid, TransactionId: base + 22, Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, AccountId: base + 1, RelatedAccountId: base + 2, RelatedId: base + 23, CategoryId: base + 15, Amount: 400, RelatedAccountAmount: 300, TransactionTime: transactionTime + 2, TimezoneUtcOffset: 480, Comment: "Existing transfer"},
			{Uid: uid, TransactionId: base + 23, Type: models.TRANSACTION_DB_TYPE_TRANSFER_IN, AccountId: base + 2, RelatedAccountId: base + 1, RelatedId: base + 22, CategoryId: base + 15, Amount: 300, RelatedAccountAmount: 400, TransactionTime: transactionTime + 3, TimezoneUtcOffset: 480, Comment: "Existing transfer"},
			{Uid: uid, TransactionId: base + 24, Type: models.TRANSACTION_DB_TYPE_EXPENSE, AccountId: base + 1, CategoryId: base + 13, Amount: 50, TransactionTime: transactionTime + 4, Deleted: true, Comment: "Previously deleted"},
		})
		require.NoError(t, err)
		_, err = engine.Insert(&models.TransactionTagGroup{Uid: uid, TagGroupId: base + 30, Name: "Existing group"}, &models.TransactionTag{Uid: uid, TagId: base + 31, TagGroupId: base + 30, Name: "Existing tag"}, &models.TransactionTagIndex{Uid: uid, TagIndexId: base + 32, TransactionId: base + 21, TagId: base + 31}, &models.TransactionPictureInfo{Uid: uid, PictureId: base + 33, TransactionId: base + 21, PictureExtension: "png"}, &models.TransactionTemplate{Uid: uid, TemplateId: base + 34, TemplateType: models.TRANSACTION_TEMPLATE_TYPE_NORMAL, Name: "Existing template", Type: models.TRANSACTION_TYPE_EXPENSE, AccountId: base + 1, CategoryId: base + 13, Amount: 100})
		require.NoError(t, err)
	}
	readStoredRows := func() any {
		var users []models.User
		var accounts []models.Account
		var transactions []models.Transaction
		require.NoError(t, engine.OrderBy("uid").Find(&users))
		require.NoError(t, engine.OrderBy("account_id").Find(&accounts))
		require.NoError(t, engine.OrderBy("transaction_id").Find(&transactions))
		return []any{users, accounts, transactions}
	}
	before := readStoredRows()
	cliContext := core.WrapCilContext(context.Background(), Database)
	require.NoError(t, updateAllDatabaseTablesStructure(cliContext))
	require.Equal(t, before, readStoredRows())
	for _, model := range syncModels {
		exists, err := engine.IsTableExist(model)
		require.NoError(t, err)
		require.True(t, exists)
		count, err := engine.Count(model)
		require.NoError(t, err)
		require.Zero(t, count)
	}
	t.Log("schema upgrade preserved both populated ledgers and created all six empty sync/OAuth tables")

	request := func(uid int64, method, path string, body any) *core.WebContext {
		encoded, err := json.Marshal(body)
		require.NoError(t, err)
		g, _ := gin.CreateTestContext(httptest.NewRecorder())
		g.Request = httptest.NewRequest(method, path, bytes.NewReader(encoded))
		g.Request.Header.Set("Content-Type", "application/json")
		g.Request.Header.Set("X-Timezone-Offset", "480")
		c := &core.WebContext{Context: g}
		c.SetTokenClaims(&core.UserTokenClaims{Uid: uid})
		return c
	}
	snapshot := func(uid int64) (map[string]map[string]map[string]json.RawMessage, string) {
		items := make(map[string]map[string]map[string]json.RawMessage)
		cursor, path := "", "/api/v1/sync/snapshot.json?count=2"
		for pageNumber := 0; ; pageNumber++ {
			require.Less(t, pageNumber, 20, "snapshot pagination must finish")
			value, apiErr := api.ClientSync.SnapshotHandler(request(uid, "GET", path, nil))
			require.Nil(t, apiErr)
			page := value.(map[string]any)
			require.Equal(t, "1", page["generation"])
			require.Equal(t, false, page["resetRequired"])
			if cursor == "" {
				cursor = page["cursor"].(string)
			}
			require.Equal(t, cursor, page["cursor"])
			for _, key := range []string{"accounts", "transactions", "categories", "tags", "tagGroups", "templates"} {
				if items[key] == nil {
					items[key] = make(map[string]map[string]json.RawMessage)
				}
				for _, raw := range page[key].([]json.RawMessage) {
					var item map[string]json.RawMessage
					require.NoError(t, json.Unmarshal(raw, &item))
					var id string
					require.NoError(t, json.Unmarshal(item["id"], &id))
					require.NotContains(t, items[key], id)
					items[key][id] = item
				}
			}
			if page["hasMore"] == false {
				break
			}
			path = "/api/v1/sync/snapshot.json?count=2&page_token=" + url.QueryEscape(page["nextPage"].(string))
		}
		return items, cursor
	}
	initial, cursor := snapshot(101)
	require.Equal(t, "14", cursor)
	for key, count := range map[string]int{"accounts": 2, "transactions": 3, "categories": 6, "tags": 1, "tagGroups": 1, "templates": 1} {
		require.Len(t, initial[key], count)
		for _, item := range initial[key] {
			require.JSONEq(t, `"1"`, string(item["version"]))
		}
	}
	var expense models.TransactionInfoResponse
	expenseRaw, err := json.Marshal(initial["transactions"]["10121"])
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(expenseRaw, &expense))
	require.Equal(t, int64(100), expense.SourceAmount)
	require.Equal(t, []string{"10131"}, expense.TagIds)
	require.Len(t, expense.Pictures, 1)
	require.Equal(t, "pictures/10133.png", expense.Pictures[0].OriginalUrl)
	require.JSONEq(t, `400`, string(initial["transactions"]["10122"]["sourceAmount"]))
	require.JSONEq(t, `300`, string(initial["transactions"]["10122"]["destinationAmount"]))
	require.Equal(t, before, readStoredRows(), "bootstrap must not change business rows")

	webData := func(uid, amount int64) map[string]any {
		base := uid * 100
		return map[string]any{"id": strconv.FormatInt(base+21, 10), "type": 3, "categoryId": strconv.FormatInt(base+13, 10), "time": now, "utcOffset": 480, "sourceAccountId": strconv.FormatInt(base+1, 10), "sourceAmount": amount, "comment": "Ordinary Web edit", "tagIds": []string{strconv.FormatInt(base+31, 10)}, "pictureIds": []string{strconv.FormatInt(base+33, 10)}}
	}
	// This user's first operation after upgrade is an ordinary Web edit.
	_, apiErr := api.Transactions.TransactionModifyHandler(request(102, "POST", "/api/v1/transactions/modify.json", webData(102, 125)))
	require.Nil(t, apiErr)
	second, secondCursor := snapshot(102)
	require.Equal(t, "16", secondCursor)
	require.JSONEq(t, `"2"`, string(second["transactions"]["10221"]["version"]))
	require.JSONEq(t, `"1475"`, string(second["accounts"]["10201"]["balance"]))
	var journal []models.SyncChange
	require.NoError(t, engine.Where("uid=? AND entity=? AND entity_id=?", 102, "transaction", 10221).Asc("cursor").Find(&journal))
	require.Len(t, journal, 2)
	require.Equal(t, int64(1), journal[0].Version)
	require.Equal(t, int64(2), journal[1].Version)
	var baseline models.TransactionInfoResponse
	require.NoError(t, json.Unmarshal([]byte(journal[0].Data), &baseline))
	require.Equal(t, int64(100), baseline.SourceAmount)
	t.Log("snapshot-first and ordinary-Web-write-first bootstrap both preserve the baseline and initialize generation 1")

	_, apiErr = api.Transactions.TransactionModifyHandler(request(101, "POST", "/api/v1/transactions/modify.json", webData(101, 150)))
	require.Nil(t, apiErr)
	data := webData(101, 25)
	delete(data, "id")
	delete(data, "tagIds")
	delete(data, "pictureIds")
	created, apiErr := api.Transactions.TransactionCreateHandler(request(101, "POST", "/api/v1/transactions/add.json", data))
	require.Nil(t, apiErr)
	createdId := created.(*models.TransactionInfoResponse).Id
	_, apiErr = api.Transactions.TransactionDeleteHandler(request(101, "POST", "/api/v1/transactions/delete.json", map[string]string{"id": strconv.FormatInt(createdId, 10)}))
	require.Nil(t, apiErr)
	value, apiErr := api.ClientSync.ChangesHandler(request(101, "GET", "/api/v1/sync/changes.json?generation=1&cursor="+cursor, nil))
	require.Nil(t, apiErr)
	encoded, err := json.Marshal(value)
	require.NoError(t, err)
	// Decode the public string IDs separately from the SQL journal model.
	var public struct {
		Generation string `json:"generation"`
		Cursor     string `json:"cursor"`
		Changes    []struct {
			Entity  string          `json:"entity"`
			Id      int64           `json:"id,string"`
			Version int64           `json:"version,string"`
			Deleted bool            `json:"deleted"`
			Data    json.RawMessage `json:"data"`
		} `json:"changes"`
	}
	require.NoError(t, json.Unmarshal(encoded, &public))
	require.Equal(t, "1", public.Generation)
	require.Equal(t, "20", public.Cursor)
	require.Len(t, public.Changes, 6)
	versions := make(map[int64][]int64)
	for _, change := range public.Changes {
		versions[change.Id] = append(versions[change.Id], change.Version)
		if change.Deleted {
			require.Equal(t, createdId, change.Id)
			require.JSONEq(t, `null`, string(change.Data))
		}
	}
	require.Equal(t, []int64{2, 3, 4}, versions[10101])
	require.Equal(t, []int64{2}, versions[10121])
	require.Equal(t, []int64{1, 2}, versions[createdId])
	require.True(t, public.Changes[5].Deleted)

	storedAfterWrites := readStoredRows()
	require.NoError(t, engine.Close())
	engine = open()
	require.NoError(t, updateAllDatabaseTablesStructure(cliContext))
	require.Equal(t, storedAfterWrites, readStoredRows())
	final, finalCursor := snapshot(101)
	require.Equal(t, "20", finalCursor)
	require.Len(t, final["transactions"], 3)
	require.JSONEq(t, `"1450"`, string(final["accounts"]["10101"]["balance"]))
	require.JSONEq(t, `"300"`, string(final["accounts"]["10102"]["balance"]))
	var states []models.SyncLedgerState
	require.NoError(t, engine.Asc("uid").Find(&states))
	require.Len(t, states, 2)
	for _, state := range states {
		require.Equal(t, int64(1), state.Generation)
		require.True(t, state.Initialized)
	}
	count, err := engine.Count(new(models.SyncChange))
	require.NoError(t, err)
	require.Equal(t, int64(36), count)
	t.Log("ordinary Web modify/create/delete journaled versions and tombstones; reopen and repeated upgrade preserved balances and cursors without duplicate bootstrap")
}
