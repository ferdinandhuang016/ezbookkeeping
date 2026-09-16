// Execute the existing Web decimal implementation to make native regression fixtures.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const {Decimal} = require('../../node_modules/decimal.js');
const root = path.resolve(__dirname, '../..');
const filename = path.join(root, 'src/lib/numeral.ts');
const source = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.ES2022, true);
const printer = ts.createPrinter();
const body = source.statements.filter(node => !ts.isImportDeclaration(node)).map(node => printer.printNode(ts.EmitHint.Unspecified, node, source)).join('\n');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(body, {compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022}}).outputText, {
  exports: exportsObject, Decimal, AMOUNT_FACTOR: 100,
  DEFAULT_DECIMAL_NUMBER_COUNT: 2, MAX_SUPPORTED_DECIMAL_NUMBER_COUNT: 8,
  DISPLAY_HIDDEN_AMOUNT: '***', isDefined: value => value !== undefined && value !== null,
  isNumber: value => typeof value === 'number', isString: value => typeof value === 'string',
  logger: {warn: error => {throw new Error(error);}},
}, {filename});
const {parseBigDecimal, getExchangedAmountByRate} = exportsObject;
const cases = [['1', '2', '1'], ['-1', '2', '1'], ['3', '2', '1'], ['-3', '2', '1'], ['999999999999999', '7.12345678', '0.98765432']].map(([amount, fromRate, toRate]) => ({amount, fromRate, toRate, expected: getExchangedAmountByRate(parseBigDecimal(amount), fromRate, toRate).truncate().toString()}));
const half = value => getExchangedAmountByRate(parseBigDecimal(value), '2', '1').truncate();
const grouped = {sameAccountCategory: half('2').toString(), differentAccounts: half('1').add(half('1')).toString(), differentCategories: half('1').add(half('1')).toString(), differentMonths: half('1').add(half('1')).toString(), overviewSameCurrency: half('2').toString()};
fs.mkdirSync(path.join(root, 'flutter_app/test/fixtures'), {recursive: true});
fs.writeFileSync(path.join(root, 'flutter_app/test/fixtures/web_exchange.json'), JSON.stringify({cases, grouped}, null, 2) + '\n');
console.log(`Generated ${cases.length} Web exchange cases and ${Object.keys(grouped).length} aggregation cases`);
