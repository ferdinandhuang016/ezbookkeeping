// Derive the mobile data menu from the original TypeScript class.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const filename = path.join(root, 'src/core/statistics.ts');
const source = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.ES2022, true);
const names = new Set(['StatisticsAnalysisType', 'ChartDataType']);
const declarations = source.statements.filter(item => item.name && names.has(item.name.text));
const code = declarations.map(item => ts.createPrinter().printNode(ts.EmitHint.Unspecified, item, source)).join('\n');
const result = {};
vm.runInNewContext(ts.transpileModule(code, {compilerOptions: {module: ts.ModuleKind.CommonJS}}).outputText, {exports: result});
const fixture = [0, 1, 2].map(analysis => result.ChartDataType.values(analysis).map(item => ({type: item.type, name: item.name})));
fs.writeFileSync(path.join(root, 'flutter_app/test/fixtures/web_statistics_types.json'), JSON.stringify(fixture, null, 2) + '\n');
console.log('Generated original mobile chart data menus for three analyses');
