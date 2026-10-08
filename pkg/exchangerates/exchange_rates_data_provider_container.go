package exchangerates

import (
	"crypto/tls"
	"time"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/services"
	"github.com/mayswind/ezbookkeeping/pkg/settings"
)

func init() {
	services.HistoricalExchangeRatesProvider = func(c core.Context, uid int64, date string) (*models.LatestExchangeRateResponse, error) {
		config := settings.Container.GetCurrentConfig()
		rates, err := Container.GetExchangeRatesByDate(c, uid, config, date)
		if err == nil && rates == nil && date == time.Now().Format("2006-01-02") {
			return Container.GetLatestExchangeRates(c, uid, config)
		}
		return rates, err
	}
}

// ExchangeRatesDataProviderContainer contains the current exchange rates data provider
type ExchangeRatesDataProviderContainer struct {
	current ExchangeRatesDataProvider
}

// Initialize a exchange rates data provider container singleton instance
var (
	Container = &ExchangeRatesDataProviderContainer{}
)

// InitializeExchangeRatesDataSource initializes the current exchange rates data source according to the config
func InitializeExchangeRatesDataSource(config *settings.Config) error {
	if config.ExchangeRatesDataSource == settings.CentralBankOfArgentinaDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &CentralBankOfArgentinaDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NationalBankOfBelarusDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NationalBankOfBelarusDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.BankOfCanadaDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &BankOfCanadaDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.CzechNationalBankDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &CzechNationalBankDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.DanmarksNationalbankDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &DanmarksNationalbankDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.EuroCentralBankDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &EuroCentralBankDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NationalBankOfGeorgiaDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NationalBankOfGeorgiaDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.CentralBankOfHungaryDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &CentralBankOfHungaryDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.BankOfIsraelDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &BankOfIsraelDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.BankOfItalyDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &BankOfItalyDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NationalBankOfKazakhstanDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NationalBankOfKazakhstanDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.CentralBankOfMalaysiaDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &CentralBankOfMalaysiaDataSource{}, tls.TLS_RSA_WITH_AES_128_GCM_SHA256)
		return nil
	} else if config.ExchangeRatesDataSource == settings.CentralBankOfMyanmarDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &CentralBankOfMyanmarDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NorgesBankDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NorgesBankDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NationalBankOfPolandDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NationalBankOfPolandDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NationalBankOfRomaniaDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NationalBankOfRomaniaDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.BankOfRussiaDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &BankOfRussiaDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.SwissNationalBankDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &SwissNationalBankDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.NationalBankOfUkraineDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &NationalBankOfUkraineDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.CentralBankOfUzbekistanDataSource {
		Container.current = newCommonHttpExchangeRatesDataProvider(config, &CentralBankOfUzbekistanDataSource{})
		return nil
	} else if config.ExchangeRatesDataSource == settings.StateAdministrationOfForeignExchangeDataSource {
		Container.current = newStateAdministrationOfForeignExchangeDataProvider(config)
		return nil
	} else if config.ExchangeRatesDataSource == settings.UserCustomExchangeRatesDataSource {
		Container.current = newUserCustomExchangeRatesDataProvider()
		return nil
	}

	return errs.ErrInvalidExchangeRatesDataSource
}

// GetExchangeRatesByDate returns exchange rates for the specified date when the current provider supports it.
func (e *ExchangeRatesDataProviderContainer) GetExchangeRatesByDate(c core.Context, uid int64, currentConfig *settings.Config, date string) (*models.LatestExchangeRateResponse, error) {
	provider, ok := e.current.(HistoricalExchangeRatesDataProvider)

	if !ok {
		return nil, nil
	}

	return provider.GetExchangeRatesByDate(c, uid, currentConfig, date)
}

// GetLatestExchangeRates returns the latest exchange rates data from the current exchange rates data source
func (e *ExchangeRatesDataProviderContainer) GetLatestExchangeRates(c core.Context, uid int64, currentConfig *settings.Config) (*models.LatestExchangeRateResponse, error) {
	if Container.current == nil {
		return nil, errs.ErrInvalidExchangeRatesDataSource
	}

	return e.current.GetLatestExchangeRates(c, uid, currentConfig)
}
