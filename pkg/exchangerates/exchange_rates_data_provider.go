package exchangerates

import (
	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/settings"
)

// ExchangeRatesDataProvider defines the structure of exchange rates data provider
type ExchangeRatesDataProvider interface {
	// GetLatestExchangeRates returns the common response entities
	GetLatestExchangeRates(c core.Context, uid int64, currentConfig *settings.Config) (*models.LatestExchangeRateResponse, error)
}

// HistoricalExchangeRatesDataProvider defines an exchange-rate provider that can query a specified date.
type HistoricalExchangeRatesDataProvider interface {
	GetExchangeRatesByDate(c core.Context, uid int64, currentConfig *settings.Config, date string) (*models.LatestExchangeRateResponse, error)
}
