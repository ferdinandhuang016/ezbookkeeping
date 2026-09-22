package models_test

import (
	"path/filepath"
	"testing"

	_ "github.com/mattn/go-sqlite3"
	"github.com/stretchr/testify/require"
	"xorm.io/xorm"

	"github.com/mayswind/ezbookkeeping/pkg/models"
)

func TestTransactionOriginalAmountColumnsCanUpgradePopulatedSQLiteTable(t *testing.T) {
	engine, err := xorm.NewEngine("sqlite3", filepath.Join(t.TempDir(), "transaction-upgrade.db"))
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, engine.Close()) })

	require.NoError(t, engine.Sync2(new(models.Transaction)))
	_, err = engine.Insert(&models.Transaction{Uid: 1, TransactionId: 2, Amount: 300})
	require.NoError(t, err)
	_, err = engine.Exec(`ALTER TABLE "transaction" DROP COLUMN "original_currency"`)
	require.NoError(t, err)
	_, err = engine.Exec(`ALTER TABLE "transaction" DROP COLUMN "original_amount"`)
	require.NoError(t, err)

	require.NoError(t, engine.Sync2(new(models.Transaction)))

	transaction := &models.Transaction{}
	has, err := engine.Where("uid=? AND transaction_id=?", 1, 2).Get(transaction)
	require.NoError(t, err)
	require.True(t, has)
	require.Equal(t, int64(300), transaction.Amount)
	require.Empty(t, transaction.OriginalCurrency)
	require.Zero(t, transaction.OriginalAmount)
}
