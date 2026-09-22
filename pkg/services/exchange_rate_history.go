package services

import (
	"time"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/datastore"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

// ExchangeRateHistoryService retains and queries exchange-rate snapshots.
type ExchangeRateHistoryService struct {
	ServiceUsingDB
}

// ExchangeRateHistory is the exchange-rate history service singleton.
var ExchangeRateHistory = &ExchangeRateHistoryService{
	ServiceUsingDB: ServiceUsingDB{
		container: datastore.Container,
	},
}

// SaveExchangeRates stores a snapshot without discarding an existing snapshot with the same timestamp.
func (s *ExchangeRateHistoryService) SaveExchangeRates(c core.Context, uid int64, rateDate string, response *models.LatestExchangeRateResponse) error {
	if uid <= 0 {
		return errs.ErrUserIdInvalid
	}

	history, err := models.NewExchangeRateHistory(uid, rateDate, response)

	if err != nil {
		return err
	}

	history.CreatedUnixTime = time.Now().Unix()
	sess := s.UserDataDB(uid).NewSession(c)
	existing := &models.ExchangeRateHistory{}
	has, err := sess.Where("uid=? AND rate_date=?", uid, rateDate).Get(existing)

	if err != nil {
		return err
	}

	if has {
		if existing.UpdateTime >= response.UpdateTime {
			return nil
		}

		_, err = sess.Where("uid=? AND rate_date=?", uid, rateDate).
			Cols("update_time", "data_source", "reference_url", "base_currency", "exchange_rates").Update(history)
		return err
	}

	_, err = sess.Insert(history)
	return err
}

// GetExchangeRates returns the newest retained snapshot inside the requested time range.
func (s *ExchangeRateHistoryService) GetExchangeRates(c core.Context, uid int64, rateDate string) (*models.LatestExchangeRateResponse, error) {
	if uid <= 0 {
		return nil, errs.ErrUserIdInvalid
	}

	history := &models.ExchangeRateHistory{}
	has, err := s.UserDataDB(uid).NewSession(c).
		Where("uid=? AND rate_date=?", uid, rateDate).Get(history)

	if err != nil || !has {
		return nil, err
	}

	return history.ToLatestExchangeRateResponse()
}

// DeleteAllExchangeRates deletes all retained snapshots for a user.
func (s *ExchangeRateHistoryService) DeleteAllExchangeRates(c core.Context, uid int64) error {
	if uid <= 0 {
		return errs.ErrUserIdInvalid
	}

	_, err := s.UserDataDB(uid).NewSession(c).Where("uid=?", uid).Delete(&models.ExchangeRateHistory{})
	return err
}
