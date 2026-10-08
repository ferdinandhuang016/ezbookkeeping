package api

import (
	"testing"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

func TestTransferRequestAddsServiceChargeToSourceDebit(t *testing.T) {
	request := &models.TransactionCreateRequest{
		Type:                 models.TRANSACTION_TYPE_TRANSFER,
		SourceAmount:         100,
		ServiceCharge:        2,
		DestinationAmount:    100,
		SourceAccountId:      1,
		DestinationAccountId: 2,
	}
	transaction := Transactions.createNewTransactionModel(1, request, "")
	if transaction.Amount != 102 || transaction.ServiceCharge != 2 || transaction.RelatedAccountAmount != 100 {
		t.Fatalf("unexpected transfer model: %+v", transaction)
	}

	templateRequest := &models.TransactionTemplateCreateRequest{
		TemplateType:         models.TRANSACTION_TEMPLATE_TYPE_NORMAL,
		Type:                 models.TRANSACTION_TYPE_TRANSFER,
		SourceAmount:         100,
		ServiceCharge:        2,
		DestinationAmount:    100,
		SourceAccountId:      1,
		DestinationAccountId: 2,
	}
	template, err := TransactionTemplates.createNewTemplateModel(&core.WebContext{}, 1, templateRequest, 0)
	if err != nil {
		t.Fatal(err)
	}
	if template.Amount != 102 || template.ServiceCharge != 2 || template.RelatedAccountAmount != 100 {
		t.Fatalf("unexpected template model: %+v", template)
	}
}
