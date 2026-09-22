package exchangerates

import (
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/mayswind/ezbookkeeping/pkg/converters/datatable"
	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

type safeTestDataTable struct {
	headers             []string
	rows                [][]string
	reportedColumnCount int
}

type safeTestDataRow struct {
	data                []string
	reportedColumnCount int
}

type safeTestDataRowIterator struct {
	rows                [][]string
	index               int
	reportedColumnCount int
}

func (t *safeTestDataTable) DataRowCount() int           { return len(t.rows) }
func (t *safeTestDataTable) HeaderColumnNames() []string { return t.headers }
func (t *safeTestDataTable) DataRowIterator() datatable.BasicDataTableRowIterator {
	return &safeTestDataRowIterator{rows: t.rows, reportedColumnCount: t.reportedColumnCount}
}
func (r *safeTestDataRow) ColumnCount() int {
	if r.reportedColumnCount > 0 {
		return r.reportedColumnCount
	}
	return len(r.data)
}
func (r *safeTestDataRow) GetData(columnIndex int) string { return r.data[columnIndex] }
func (i *safeTestDataRowIterator) HasNext() bool          { return i.index < len(i.rows) }
func (i *safeTestDataRowIterator) CurrentRowId() string   { return strconv.Itoa(i.index) }
func (i *safeTestDataRowIterator) Next() datatable.BasicDataTableRow {
	row := &safeTestDataRow{data: i.rows[i.index], reportedColumnCount: i.reportedColumnCount}
	i.index++
	return row
}

func TestStateAdministrationOfForeignExchangeTableUsesLatestPublishedDate(t *testing.T) {
	location := time.FixedZone("CST", 8*60*60)
	requestedDate, err := time.ParseInLocation(stateAdministrationOfForeignExchangeDateFormat, "2026-09-17", location)
	require.NoError(t, err)
	table := &safeTestDataTable{
		headers: []string{"日期", "美元", "澳门元", "韩元"},
		rows: [][]string{
			{"2026-09-14", "676.98", "119.38", "20034.0"},
			{"2026-09-16", "676.28", "119.53", "20351.0"},
		},
	}

	response := parseStateAdministrationOfForeignExchangeTable(core.NewNullContext(), table, requestedDate)
	require.NotNil(t, response)
	assert.Equal(t, "CNY", response.BaseCurrency)
	assert.Equal(t, time.Date(2026, 9, 16, 9, 15, 0, 0, location).Unix(), response.UpdateTime)
	assert.InDelta(t, 100/676.28, getSafeTestRate(t, response.ExchangeRates, "USD"), 0.000000000001)
	assert.InDelta(t, 119.53/100, getSafeTestRate(t, response.ExchangeRates, "MOP"), 0.000000000001)
	assert.InDelta(t, 20351.0/100, getSafeTestRate(t, response.ExchangeRates, "KRW"), 0.000000000001)
}

func TestStateAdministrationOfForeignExchangeTableDoesNotUseFutureRow(t *testing.T) {
	location := time.FixedZone("CST", 8*60*60)
	requestedDate, err := time.ParseInLocation(stateAdministrationOfForeignExchangeDateFormat, "2026-09-15", location)
	require.NoError(t, err)
	table := &safeTestDataTable{
		headers: []string{"日期", "美元"},
		rows: [][]string{
			{"2026-09-14", "676.98"},
			{"2026-09-16", "676.28"},
		},
	}

	response := parseStateAdministrationOfForeignExchangeTable(core.NewNullContext(), table, requestedDate)
	require.NotNil(t, response)
	assert.Equal(t, time.Date(2026, 9, 14, 9, 15, 0, 0, location).Unix(), response.UpdateTime)
}

func TestStateAdministrationOfForeignExchangeTableIncludesFinalThaiBahtColumn(t *testing.T) {
	location := time.FixedZone("CST", 8*60*60)
	requestedDate, err := time.ParseInLocation(stateAdministrationOfForeignExchangeDateFormat, "2026-09-16", location)
	require.NoError(t, err)
	headers := []string{
		"日期", "美元", "欧元", "日元", "港元", "英镑", "澳元", "新西兰元", "新加坡元", "瑞士法郎", "加元", "澳门元", "林吉特",
		"卢布", "兰特", "韩元", "迪拉姆", "里亚尔", "福林", "兹罗提", "丹麦克朗", "瑞典克朗", "挪威克朗", "里拉", "比索",
	}
	row := make([]string, 26)
	row[0] = "2026-09-16"
	row[25] = "495.19"
	table := &safeTestDataTable{headers: headers, rows: [][]string{row}, reportedColumnCount: 25}

	response := parseStateAdministrationOfForeignExchangeTable(core.NewNullContext(), table, requestedDate)
	require.NotNil(t, response)
	assert.InDelta(t, 495.19/100, getSafeTestRate(t, response.ExchangeRates, "THB"), 0.000000000001)
}

func getSafeTestRate(t *testing.T, rates models.LatestExchangeRateSlice, currency string) float64 {
	t.Helper()

	for _, rate := range rates {
		if rate.Currency == currency {
			value, err := strconv.ParseFloat(rate.Rate, 64)
			require.NoError(t, err)
			return value
		}
	}

	require.Fail(t, "currency not found", currency)
	return 0
}
