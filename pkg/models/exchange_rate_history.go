package models

import "encoding/json"

// ExchangeRateHistory represents a retained exchange-rate snapshot for one user.
type ExchangeRateHistory struct {
	Uid             int64  `xorm:"PK NOT NULL"`
	RateDate        string `xorm:"PK VARCHAR(10) NOT NULL"`
	UpdateTime      int64  `xorm:"INDEX(IDX_exchange_rate_history_uid_update_time) NOT NULL"`
	DataSource      string `xorm:"VARCHAR(64) NOT NULL"`
	ReferenceUrl    string `xorm:"VARCHAR(255) NOT NULL"`
	BaseCurrency    string `xorm:"VARCHAR(3) NOT NULL"`
	ExchangeRates   string `xorm:"TEXT NOT NULL"`
	CreatedUnixTime int64
}

// ExchangeRateHistoryRequest represents a historical exchange-rate query.
type ExchangeRateHistoryRequest struct {
	Date string `form:"date" binding:"required"`
}

// NewExchangeRateHistory creates a retained snapshot from an exchange-rate response.
func NewExchangeRateHistory(uid int64, rateDate string, response *LatestExchangeRateResponse) (*ExchangeRateHistory, error) {
	rates, err := json.Marshal(response.ExchangeRates)

	if err != nil {
		return nil, err
	}

	return &ExchangeRateHistory{
		Uid:           uid,
		RateDate:      rateDate,
		UpdateTime:    response.UpdateTime,
		DataSource:    response.DataSource,
		ReferenceUrl:  response.ReferenceUrl,
		BaseCurrency:  response.BaseCurrency,
		ExchangeRates: string(rates),
	}, nil
}

// ToLatestExchangeRateResponse converts a retained snapshot to the common response.
func (h *ExchangeRateHistory) ToLatestExchangeRateResponse() (*LatestExchangeRateResponse, error) {
	rates := make(LatestExchangeRateSlice, 0)

	if err := json.Unmarshal([]byte(h.ExchangeRates), &rates); err != nil {
		return nil, err
	}

	return &LatestExchangeRateResponse{
		DataSource:    h.DataSource,
		ReferenceUrl:  h.ReferenceUrl,
		UpdateTime:    h.UpdateTime,
		BaseCurrency:  h.BaseCurrency,
		ExchangeRates: rates,
	}, nil
}
