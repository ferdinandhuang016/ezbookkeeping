const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const Decimal = require('../../node_modules/decimal.js');
const root = path.resolve(__dirname, '../..');
const source = file => ts.createSourceFile(file, fs.readFileSync(path.join(root, file), 'utf8'), ts.ScriptTarget.ES2022, true);
const printed = (node, file) => ts.createPrinter().printNode(ts.EmitHint.Unspecified, node, file);
const run = (code, context = {}) => {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(code, {compilerOptions: {module: ts.ModuleKind.CommonJS}}).outputText, {exports, ...context});
  return exports;
};
const numeral = source('src/lib/numeral.ts');
const formatNode = numeral.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === 'formatExchangeRateAmount');
const western = {digitZero: '0', formatBigDecimal: value => value.toFixed()};
const format = run(printed(formatNode, numeral), {
  NumeralSystem: {Default: western}, DecimalSeparator: {Dot: {symbol: '.'}},
  appendDigitGroupingSymbolAndDecimalSeparator: value => value,
}).formatExchangeRateAmount;
const inputs = [
  [100, '1', '12'], [0, '1', '12'], [100, '1', '0.00000001234567'],
  [-100, '1', '0.00000001234567'], [123400, '1', '1'],
  [100, '3', '2'], [999999999999999, '7', '0.3'], [1, '7', '1'],
];
const display = inputs.map(([cents, from, to]) => ({cents, from, to, expected: format(new Decimal(to).div(from).mul(new Decimal(cents).div(100)), {})}));
const updateSource = fs.readFileSync(path.join(root, 'src/views/mobile/exchangerates/UpdatePage.vue'), 'utf8');
const script = updateSource.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)[1];
const update = ts.createSourceFile('UpdatePage.ts', script, ts.ScriptTarget.ES2022, true);
let rateExpression;
const visit = node => {
  if (ts.isPropertyAssignment(node) && node.name.getText(update) === 'rate') rateExpression = node.initializer;
  ts.forEachChild(node, visit);
};
visit(update);
const rateInputs = [['1','3'],['2','3'],['1','7'],['7.1000','1'],['0.0001','999999999.9999']];
const updateRates = rateInputs.map(([target, base]) => ({target, base, wireRate: vm.runInNewContext(printed(rateExpression, update), {targetCurrencyAmount: {value: Number(target)}, defaultCurrencyAmount: {value: Number(base)}}).toString()}));
const maps = source('src/consts/map.ts');
const tiles = run(maps.getText()).LEAFLET_TILE_SOURCES;
const websites = Object.fromEntries(Object.entries(tiles).map(([id, value]) => [id, value.website]));
for (const id of ['googlemap', 'baidumap', 'amap']) {
  const provider = source(`src/lib/map/${id}.ts`);
  const cls = provider.statements.find(ts.isClassDeclaration);
  const method = cls.members.find(node => ts.isMethodDeclaration(node) && node.name.getText(provider) === 'getWebsite');
  websites[id] = method.body.statements.find(ts.isReturnStatement).expression.text;
}
fs.writeFileSync(path.join(root, 'flutter_app/test/fixtures/web_exchange_about.json'), JSON.stringify({display, updateRates, websites}, null, 2) + '\n');
console.log(`Generated ${display.length} original display cases, ${updateRates.length} update ratios and ${Object.keys(websites).length} provider websites`);
