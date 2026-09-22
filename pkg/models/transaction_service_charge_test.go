package models

import "testing"

func TestTransferResponseSeparatesServiceChargeFromTransferAmount(t *testing.T) {
	transferOut := &Transaction{
		Type:                 TRANSACTION_DB_TYPE_TRANSFER_OUT,
		AccountId:            1,
		RelatedAccountId:     2,
		Amount:               102,
		ServiceCharge:        2,
		RelatedAccountAmount: 100,
	}
	response := transferOut.ToTransactionInfoResponse(nil, true)
	if response.SourceAmount != 100 || response.ServiceCharge != 2 || *response.DestinationAmount != 100 {
		t.Fatalf("unexpected transfer-out response: %+v", response)
	}

	transferIn := &Transaction{
		Type:                 TRANSACTION_DB_TYPE_TRANSFER_IN,
		AccountId:            2,
		RelatedAccountId:     1,
		Amount:               100,
		ServiceCharge:        2,
		RelatedAccountAmount: 102,
	}
	response = transferIn.ToTransactionInfoResponse(nil, true)
	if response.SourceAmount != 100 || response.ServiceCharge != 2 || *response.DestinationAmount != 100 {
		t.Fatalf("unexpected transfer-in response: %+v", response)
	}
}

func TestTransferTemplateResponseSeparatesServiceCharge(t *testing.T) {
	template := &TransactionTemplate{
		Type:                 TRANSACTION_TYPE_TRANSFER,
		Amount:               102,
		ServiceCharge:        2,
		RelatedAccountAmount: 100,
	}
	response := template.toTransactionInfoResponse(0)
	if response.SourceAmount != 100 || response.ServiceCharge != 2 || *response.DestinationAmount != 100 {
		t.Fatalf("unexpected template response: %+v", response)
	}
}
