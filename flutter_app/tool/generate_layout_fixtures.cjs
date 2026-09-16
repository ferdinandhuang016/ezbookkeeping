const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const root = path.resolve(__dirname, '../..');
function declarations(file, names) {
  const source = ts.createSourceFile(file, fs.readFileSync(path.join(root, file), 'utf8'), ts.ScriptTarget.ES2022, true);
  return source.statements.filter(node => node.name && names.includes(node.name.text))
    .map(node => ts.createPrinter().printNode(ts.EmitHint.Unspecified, node, source)).join('\n');
}
const source = declarations('src/lib/common.ts', ['isFunction', 'isDefined', 'isObject', 'isArray', 'isString', 'isNumber', 'isInteger', 'isBoolean', 'isHextualColor']) + '\n' +
  declarations('src/core/numeral.ts', ['AmountFilterType']) + '\n' +
  declarations('src/lib/overview_layout.ts', ['normalizeOverviewWidgetSetting', 'normalizeOverviewWidgetSettings', 'normalizeMobileOverviewLayout']);
const definitions = JSON.parse(fs.readFileSync(path.join(root, 'flutter_app/assets/reference/overview_widgets.json')));
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(source, {compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022}}).outputText, {
  exports: exportsObject, MOBILE_OVERVIEW_LAYOUT_MAX_WIDGETS: 100, MOBILE_OVERVIEW_WIDGET_DEFINITIONS: definitions,
  // parse always returns an array (including invalid/empty filters), hence is
  // truthy in the original normalizer; the text itself is preserved unchanged.
  TransactionTagFilter: {parse: () => []},
});
const inputs = [
  {widgets: Object.entries(definitions).map(([type, value], i) => ({id: `widget-${i}`, type, settings: value.defaultSettings}))},
  {widgets: [null, {}, {id: 'unknown', type: 'future-widget'}, {id: 'month', type: 'current-month-overview', settings: {height: 99, darkBackgroundColor: 'ABCDEF', lightBackgroundColor: '#000', unknown: true}}, {id: 'month', type: 'asset-summary'}, {id: 'period', type: 'period-income-expense', settings: {dateRanges: [9, 1, 1, 999]}}, {id: 'recent', type: 'recent-transactions', settings: {accountIds: ['a', 1, 'b'], amountFilter: 'bt:-2:20', tagFilter: 'invalid-preserved', itemCount: 999, title: '   ', showTitle: false}}]},
  {widgets: Array.from({length: 105}, (_, i) => ({id: `widget-${i}`, type: 'asset-summary'}))},
  {widgets: []},
];
const fixtures = inputs.map(input => ({input, expected: exportsObject.normalizeMobileOverviewLayout(input)}));
fs.writeFileSync(path.join(root, 'flutter_app/test/fixtures/web_mobile_layout.json'), JSON.stringify(fixtures, null, 2) + '\n');
console.log(`Generated ${fixtures.length} original Web layout cases`);
