package exchangerates

import (
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/mayswind/ezbookkeeping/pkg/converters/datatable"
	"github.com/mayswind/ezbookkeeping/pkg/converters/excel"
	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/httpclient"
	"github.com/mayswind/ezbookkeeping/pkg/log"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/settings"
	"github.com/mayswind/ezbookkeeping/pkg/utils"
)

const stateAdministrationOfForeignExchangeUrl = "https://www.safe.gov.cn/AppStructured/hlw/exportRMBExcel.do"
const stateAdministrationOfForeignExchangeReferenceUrl = "https://www.safe.gov.cn/safe/rmbhlzjj/"
const stateAdministrationOfForeignExchangeDataSource = "State Administration of Foreign Exchange"
const stateAdministrationOfForeignExchangeBaseCurrency = "CNY"
const stateAdministrationOfForeignExchangeDateFormat = "2006-01-02"
const stateAdministrationOfForeignExchangeLookbackDays = 30

var stateAdministrationOfForeignExchangeCurrencyCodes = map[string]string{
	"美元": "USD", "欧元": "EUR", "日元": "JPY", "港元": "HKD", "英镑": "GBP",
	"澳元": "AUD", "新西兰元": "NZD", "新加坡元": "SGD", "瑞士法郎": "CHF", "加元": "CAD",
	"澳门元": "MOP", "林吉特": "MYR", "卢布": "RUB", "兰特": "ZAR", "韩元": "KRW",
	"迪拉姆": "AED", "里亚尔": "SAR", "福林": "HUF", "兹罗提": "PLN", "丹麦克朗": "DKK",
	"瑞典克朗": "SEK", "挪威克朗": "NOK", "里拉": "TRY", "比索": "MXN", "泰铢": "THB",
}

// SAFE quotes these currencies as foreign currency per 100 CNY. The other ten currencies are quoted as CNY per 100 foreign currency.
var stateAdministrationOfForeignExchangeIndirectCurrencies = map[string]bool{
	"MOP": true, "MYR": true, "RUB": true, "ZAR": true, "KRW": true,
	"AED": true, "SAR": true, "HUF": true, "PLN": true, "DKK": true,
	"SEK": true, "NOK": true, "TRY": true, "MXN": true, "THB": true,
}

// StateAdministrationOfForeignExchangeDataProvider retrieves current and historical RMB central parity rates from SAFE.
type StateAdministrationOfForeignExchangeDataProvider struct {
	httpClient *http.Client
}

// GetLatestExchangeRates returns the newest rate published no later than today in China Standard Time.
func (p *StateAdministrationOfForeignExchangeDataProvider) GetLatestExchangeRates(c core.Context, uid int64, currentConfig *settings.Config) (*models.LatestExchangeRateResponse, error) {
	today := time.Now().In(time.FixedZone("CST", 8*60*60)).Format(stateAdministrationOfForeignExchangeDateFormat)
	return p.GetExchangeRatesByDate(c, uid, currentConfig, today)
}

// GetExchangeRatesByDate returns the specified date's rate, falling back to the most recent publication within 30 days.
func (p *StateAdministrationOfForeignExchangeDataProvider) GetExchangeRatesByDate(c core.Context, uid int64, currentConfig *settings.Config, date string) (*models.LatestExchangeRateResponse, error) {
	location := time.FixedZone("CST", 8*60*60)
	requestedDate, err := time.ParseInLocation(stateAdministrationOfForeignExchangeDateFormat, date, location)

	if err != nil {
		return nil, err
	}

	today, _ := time.ParseInLocation(stateAdministrationOfForeignExchangeDateFormat, time.Now().In(location).Format(stateAdministrationOfForeignExchangeDateFormat), location)

	if requestedDate.After(today) {
		return nil, nil
	}

	form := url.Values{}
	form.Set("startDate", requestedDate.AddDate(0, 0, -stateAdministrationOfForeignExchangeLookbackDays).Format(stateAdministrationOfForeignExchangeDateFormat))
	form.Set("endDate", date)
	form.Set("queryYN", "true")

	req, err := http.NewRequestWithContext(c, http.MethodPost, stateAdministrationOfForeignExchangeUrl, strings.NewReader(form.Encode()))

	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := p.httpClient.Do(req)

	if err != nil {
		log.Errorf(c, "[state_administration_of_foreign_exchange_data_provider.GetExchangeRatesByDate] failed to request exchange rates on date \"%s\" for user \"uid:%d\", because %s", date, uid, err.Error())
		return nil, errs.ErrFailedToRequestRemoteApi
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Errorf(c, "[state_administration_of_foreign_exchange_data_provider.GetExchangeRatesByDate] failed to request exchange rates on date \"%s\" for user \"uid:%d\", because response code is %d", date, uid, resp.StatusCode)
		return nil, errs.ErrFailedToRequestRemoteApi
	}

	body, err := io.ReadAll(resp.Body)

	if err != nil {
		return nil, errs.ErrFailedToRequestRemoteApi
	}

	response, err := parseStateAdministrationOfForeignExchangeResponse(c, body, requestedDate)

	if err != nil {
		log.Errorf(c, "[state_administration_of_foreign_exchange_data_provider.GetExchangeRatesByDate] failed to parse exchange rates on date \"%s\" for user \"uid:%d\", because %s", date, uid, err.Error())
		return nil, errs.ErrFailedToRequestRemoteApi
	}

	return response, nil
}

func parseStateAdministrationOfForeignExchangeResponse(c core.Context, content []byte, requestedDate time.Time) (*models.LatestExchangeRateResponse, error) {
	table, err := excel.CreateNewExcelMSCFBFileBasicDataTable(content, true)

	if err != nil {
		return nil, err
	}

	return parseStateAdministrationOfForeignExchangeTable(c, table, requestedDate), nil
}

func parseStateAdministrationOfForeignExchangeTable(c core.Context, table datatable.BasicDataTable, requestedDate time.Time) *models.LatestExchangeRateResponse {
	headers := table.HeaderColumnNames()
	// extrame/xls reports the last used column as a zero-based index. The shared
	// table adapter consequently omits SAFE's final 泰铢 header even though its
	// value remains readable at that index.
	if len(headers) == 25 && headers[0] == "日期" && headers[len(headers)-1] == "比索" {
		headers = append(headers, "泰铢")
	}
	iterator := table.DataRowIterator()
	var selectedRow datatable.BasicDataTableRow
	var selectedDate time.Time

	for iterator.HasNext() {
		row := iterator.Next()

		if row == nil || row.ColumnCount() < 2 {
			continue
		}

		rowDate, err := time.ParseInLocation(stateAdministrationOfForeignExchangeDateFormat, row.GetData(0), requestedDate.Location())

		if err != nil || rowDate.After(requestedDate) || (!selectedDate.IsZero() && !rowDate.After(selectedDate)) {
			continue
		}

		selectedRow = row
		selectedDate = rowDate
	}

	if selectedRow == nil {
		return nil
	}

	rates := models.LatestExchangeRateSlice{{Currency: stateAdministrationOfForeignExchangeBaseCurrency, Rate: "1"}}

	columnCount := min(len(headers), selectedRow.ColumnCount())
	if len(headers) == 26 && selectedRow.ColumnCount() == 25 {
		columnCount = 26
	}

	for columnIndex := 1; columnIndex < columnCount; columnIndex++ {
		currency, exists := stateAdministrationOfForeignExchangeCurrencyCodes[headers[columnIndex]]

		if !exists {
			continue
		}

		rawRate, err := utils.StringToFloat64(selectedRow.GetData(columnIndex))

		if err != nil || rawRate <= 0 {
			continue
		}

		rate := rawRate / 100

		if !stateAdministrationOfForeignExchangeIndirectCurrencies[currency] {
			rate = 100 / rawRate
		}

		rates = append(rates, &models.LatestExchangeRate{Currency: currency, Rate: utils.Float64ToString(rate)})
	}

	if len(rates) <= 1 {
		log.Errorf(c, "[state_administration_of_foreign_exchange_data_provider.parseTable] no valid exchange rate in row for date \"%s\"", selectedDate.Format(stateAdministrationOfForeignExchangeDateFormat))
		return nil
	}

	sort.Sort(rates)
	updateTime := time.Date(selectedDate.Year(), selectedDate.Month(), selectedDate.Day(), 9, 15, 0, 0, selectedDate.Location()).Unix()

	return &models.LatestExchangeRateResponse{
		DataSource:    stateAdministrationOfForeignExchangeDataSource,
		ReferenceUrl:  stateAdministrationOfForeignExchangeReferenceUrl,
		UpdateTime:    updateTime,
		BaseCurrency:  stateAdministrationOfForeignExchangeBaseCurrency,
		ExchangeRates: rates,
	}
}

func newStateAdministrationOfForeignExchangeDataProvider(config *settings.Config) *StateAdministrationOfForeignExchangeDataProvider {
	return &StateAdministrationOfForeignExchangeDataProvider{
		httpClient: httpclient.NewHttpClient(config.ExchangeRatesRequestTimeout, config.ExchangeRatesProxy, config.ExchangeRatesSkipTLSVerify, core.GetOutgoingUserAgent(), config.EnableDebugLog, nil),
	}
}
