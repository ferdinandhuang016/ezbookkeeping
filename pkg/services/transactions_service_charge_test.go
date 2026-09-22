package services

import (
	"testing"

	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

func TestTransferServiceChargeValidation(t *testing.T) {
	service := &TransactionService{}
	for _, transaction := range []*models.Transaction{
		{Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, AccountId: 1, RelatedAccountId: 2, Amount: 100, ServiceCharge: -1},
		{Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, AccountId: 1, RelatedAccountId: 2, Amount: 100, ServiceCharge: 101},
		{Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, AccountId: 1, RelatedAccountId: 2, Amount: models.MaximumTransactionAmount + 1, ServiceCharge: 1},
		{Type: models.TRANSACTION_DB_TYPE_EXPENSE, AccountId: 1, Amount: 100, ServiceCharge: 1},
	} {
		if err := service.isAccountIdValid(transaction); err != errs.ErrAmountInvalid {
			t.Errorf("expected invalid amount for %+v, got %v", transaction, err)
		}
	}
	valid := &models.Transaction{Type: models.TRANSACTION_DB_TYPE_TRANSFER_OUT, AccountId: 1, RelatedAccountId: 2, Amount: 102, ServiceCharge: 2}
	if err := service.isAccountIdValid(valid); err != nil {
		t.Fatalf("valid transfer rejected: %v", err)
	}
}

func TestTransferDestinationUsesRateAndCurrencyFraction(t *testing.T) {
	rates := &models.LatestExchangeRateResponse{
		BaseCurrency: "CNY",
		ExchangeRates: models.LatestExchangeRateSlice{
			{Currency: "USD", Rate: "0.14"},
			{Currency: "JPY", Rate: "20.1234"},
		},
	}
	for _, scenario := range []struct {
		currency string
		want     int64
	}{
		{currency: "USD", want: 1400},
		{currency: "JPY", want: 201200},
	} {
		got, err := convertTransferAmount(10000, "CNY", scenario.currency, rates)
		if err != nil || got != scenario.want {
			t.Errorf("%s: got %d, %v; want %d", scenario.currency, got, err, scenario.want)
		}
	}
	if _, err := convertTransferAmount(10000, "CNY", "EUR", rates); err == nil {
		t.Fatal("missing exchange rate was accepted")
	}
}
