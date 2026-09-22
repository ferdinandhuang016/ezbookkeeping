package services

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

func TestOriginalAmountValidation(t *testing.T) {
	creditCard := &models.Account{Category: models.ACCOUNT_CATEGORY_CREDIT_CARD, Currency: "CNY"}
	cash := &models.Account{Category: models.ACCOUNT_CATEGORY_CASH, Currency: "CNY"}

	tests := []struct {
		name        string
		transaction *models.Transaction
		account     *models.Account
		expected    error
	}{
		{"legacy transaction", &models.Transaction{}, creditCard, nil},
		{"amount without currency", &models.Transaction{OriginalAmount: 100}, creditCard, errs.ErrTransactionOriginalAmountInvalid},
		{"credit card expense", &models.Transaction{Type: models.TRANSACTION_DB_TYPE_EXPENSE, OriginalCurrency: "USD", OriginalAmount: 100}, creditCard, nil},
		{"same as account currency", &models.Transaction{Type: models.TRANSACTION_DB_TYPE_EXPENSE, OriginalCurrency: "CNY", OriginalAmount: 100}, creditCard, errs.ErrTransactionOriginalCurrencyNotSupported},
		{"non-credit-card account", &models.Transaction{Type: models.TRANSACTION_DB_TYPE_EXPENSE, OriginalCurrency: "USD", OriginalAmount: 100}, cash, errs.ErrTransactionOriginalCurrencyNotSupported},
		{"transfer", &models.Transaction{Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, OriginalCurrency: "USD", OriginalAmount: 100}, creditCard, errs.ErrTransactionOriginalCurrencyNotSupported},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			assert.Equal(t, test.expected, Transactions.isOriginalAmountValid(test.transaction, test.account))
		})
	}
}
