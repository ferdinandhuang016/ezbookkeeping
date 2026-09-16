// Execute the original Web store's daily gap-fill against captured API fixtures.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const sourcePath = path.join(root, 'src/stores/statistics.ts');
const source = ts.createSourceFile(sourcePath, fs.readFileSync(sourcePath, 'utf8'), ts.ScriptTarget.ES2022, true);
let declaration;
function visit(node) {
  if (ts.isVariableDeclaration(node) && node.name.getText(source) === 'assetTrendsDataWithAccountInfo') declaration = node;
  ts.forEachChild(node, visit);
}
visit(source);
const arrow = declaration.initializer.arguments[0];
const code = ts.transpileModule('const project = ' + ts.createPrinter().printNode(ts.EmitHint.Unspecified, arrow, source) + '; exports.project = project;', {compilerOptions: {target: ts.ScriptTarget.ES2022}}).outputText;
const input = JSON.parse(fs.readFileSync(path.join(root, 'flutter_app/test/fixtures/server_asset_history.json')));
function calendar(y, m, d) {
  const date = new Date(Date.UTC(y, m - 1, d));
  return {
    add: n => calendar(y, m, d + n),
    getGregorianCalendarYear: () => date.getUTCFullYear(),
    getGregorianCalendarMonth: () => date.getUTCMonth() + 1,
    getGregorianCalendarDay: () => date.getUTCDate(),
  };
}
const fixtures = input.cases.map(item => {
  const exports = {};
  vm.runInNewContext(code, {
    exports, transactionAssetTrendsData: {value: item.serverDays},
    values: Object.values, assembleAccountAndCategoryInfo: items => items,
    getDayDifference: (a, b) => (Date.UTC(b.year, b.month - 1, b.day) - Date.UTC(a.year, a.month - 1, a.day)) / 86400000,
    getYearMonthDayDateTime: calendar,
  });
  return {...item, expected: exports.project().map(day => ({
    date: [day.year, day.month, day.day], balances: Object.fromEntries(day.items.map(entry => [entry.accountId, Number(entry.amount)])),
  }))};
});
fs.writeFileSync(path.join(root, 'flutter_app/test/fixtures/web_asset_history.json'), JSON.stringify({transactions: input.transactions, cases: fixtures}, null, 2) + '\n');
console.log(`Generated ${fixtures.length} original Web daily balance fixtures`);
