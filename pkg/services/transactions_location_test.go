package services

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/mayswind/ezbookkeeping/pkg/models"
)

func TestGetRelatedTransferTransactionCopiesGeoLocationName(t *testing.T) {
	original := &models.Transaction{
		Type:            models.TRANSACTION_DB_TYPE_TRANSFER_OUT,
		TransactionTime: 100,
		GeoLatitude:     39.9,
		GeoLongitude:    116.3,
		GeoLocationName: "Office",
	}

	related := (&TransactionService{}).GetRelatedTransferTransaction(original)

	assert.Equal(t, "Office", related.GeoLocationName)
	assert.Equal(t, 39.9, related.GeoLatitude)
	assert.Equal(t, 116.3, related.GeoLongitude)
}
