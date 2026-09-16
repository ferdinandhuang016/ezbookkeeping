// Native formatting data and comparison fixtures from the original Web implementation.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const moment = require('../../node_modules/moment-timezone');
const jalali = require('../../node_modules/jalaali-js');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
function load(file) {
  file = path.resolve(file);
  if (file.endsWith('.json')) return JSON.parse(fs.readFileSync(file, 'utf8'));
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  vm.runInNewContext(source, {exports, Date, console, require: name => name.startsWith('@/') ? load(path.join(root,'src',name.slice(2))) : name.startsWith('.') ? load(path.resolve(path.dirname(file),name)) : require(name)}, {filename:file});
  return exports;
}
const langs = load(path.join(root,'src/locales/index.ts')).ALL_LANGUAGES;
const locales = {};
for (const [tag, info] of Object.entries(langs)) {
  const name = ({'zh-Hans':'zh-cn','zh-Hant':'zh-tw','pt-BR':'pt-br'})[tag] || tag;
  if (name !== 'en') require(`../../node_modules/moment/locale/${name}.js`);
  const data = moment.localeData(name);
  const meridiem = [];
  for (let minute = 0; minute < 1440; minute++) {
    const label = data.meridiem(Math.floor(minute/60), minute%60, false);
    if (!meridiem.length || meridiem.at(-1)[1] !== label) meridiem.push([minute,label]);
  }
  locales[tag] = {months:data.months(),monthsShort:data.monthsShort(),weekdays:data.weekdays(),weekdaysShort:data.weekdaysShort(),weekdaysMin:data.weekdaysMin(),meridiem};
}
const chinese = load(path.join(root,'src/lib/calendar/chinese_calendar_data.ts'));
const reference = {
  locales,
  currencies: Object.values(load(path.join(root,'src/consts/currency.ts')).ALL_CURRENCIES),
  chinese: {minYear:chinese.SUPPORTED_MIN_YEAR,maxYear:chinese.SUPPORTED_MAX_YEAR,epoch:[chinese.CHINESE_CALENDAR_FIRST_DAY_GREGORIAN_YEAR,chinese.CHINESE_CALENDAR_FIRST_DAY_GREGORIAN_MONTH,chinese.CHINESE_CALENDAR_FIRST_DAY_GREGORIAN_DAY],years:chinese.CHINESE_YEAR_DATA,solarTerms:chinese.GREGORIAN_YEAR_CHINESE_SOLAR_TERMS_DATA,
    locales:{'zh-Hans':load(path.join(root,'src/locales/calendar/chinese/zh_Hans.json')),'zh-Hant':load(path.join(root,'src/locales/calendar/chinese/zh_Hant.json'))}},
  persian:{minYear:-61,newYearMarchDays:Array.from({length:3239},(_,i)=>jalali.jalCal(i-61).march),...load(path.join(root,'src/locales/calendar/persian/fa.json'))},
};
fs.writeFileSync(path.join(root,'flutter_app/assets/reference/formatting.json'), JSON.stringify(reference)+'\n');
// These expected results execute the Web routines, independently of the Dart port.
const numeral = load(path.join(root,'src/core/numeral.ts'));
const funcs = load(path.join(root,'src/lib/numeral.ts'));
const calendar = load(path.join(root,'src/lib/calendar/chinese_calendar.ts'));
const fixtures = {amounts:[],chinese:[],persian:[],dates:[],billingRanges:[]};
for (let system=1;system<=5;system++) for (let grouping=1;grouping<=3;grouping++) {
  const value = '-123456789012345678';
  const options = {numeralSystem:numeral.NumeralSystem.valueOf(system),digitGrouping:numeral.DigitGroupingType.valueOf(grouping),digitGroupingSymbol:' ',decimalSeparator:',',decimalNumberCount:2};
  fixtures.amounts.push({system,grouping,value,expected:funcs.formatAmount(funcs.parseBigDecimal(value),options)});
}
for (const date of [[1999,2,16],[2000,2,5],[2023,3,22],[2024,2,10],[2025,7,25],[2026,9,15],[2100,12,31]]) {
  const [year,month,day]=date;
  fixtures.chinese.push({date,expected:calendar.getChineseYearMonthDayInfo({year,month,day},reference.chinese.locales['zh-Hans'])});
}
for (const date of [[1900,1,1],[2000,2,29],[2021,3,20],[2021,3,21],[2024,3,20],[2025,3,20],[2025,3,21],[2099,12,31]]) fixtures.persian.push({date,expected:jalali.toJalaali(...date)});
const datetime = load(path.join(root,'src/lib/datetime.ts'));
moment.tz.setDefault('UTC');
for(const [language,info] of Object.entries(langs)) for(const display of [1,2,3]) for(const long of [false,true]) for(const order of [1,2,3]) {
  const name=({'zh-Hans':'zh-cn','zh-Hant':'zh-tw','pt-BR':'pt-br'})[language]||language;
  const dateType=['YearMonthDay','MonthDayYear','DayMonthYear'][order-1];
  const format=info.content.format[long?'longDate':'shortDate'][dateType];
  const options={calendarType:[0,1,3][display-1],localeData:moment.localeData(name),numeralSystem:numeral.NumeralSystem.parse(info.content.default.numeralSystem),chineseCalendarLocaleData:reference.chinese.locales['zh-Hans'],persianCalendarLocaleData:reference.persian};
  const date=[2024,3,20,13,5,9];
  fixtures.dates.push({language,display,long,order,date,expected:datetime.formatUnixTime(Date.UTC(2024,2,20,13,5,9)/1000,format,options)});
}
for(const date of [[2023,2,15],[2023,2,28],[2024,2,29],[2024,3,31]]) for(const statementDay of [28,29,30,31]) for(const type of [51,52]) {
  moment.now=()=>Date.UTC(date[0],date[1]-1,date[2],12);
  fixtures.billingRanges.push({date,statementDay,type,expected:datetime.getDateRangeByBillingCycleDateType(type,1,257,statementDay)});
}
fs.writeFileSync(path.join(root,'flutter_app/test/formatting_fixtures.json'),JSON.stringify(fixtures,null,2)+'\n');
console.log(`Generated formatting data for ${Object.keys(locales).length} locales.`);
