// Run the original Web function with Moment's timezone data, without copying it.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const moment = require('../../node_modules/moment-timezone');
const root = path.resolve(__dirname, '../..');
const filename = path.join(root, 'src/lib/datetime.ts');
const source = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.ES2022, true);
const node = source.statements.find(item => ts.isFunctionDeclaration(item) && item.name.text === 'getShiftedDateRange');
const body = ts.createPrinter().printNode(ts.EmitHint.Unspecified, node, source);
const result = {};
vm.runInNewContext(ts.transpileModule(body, {compilerOptions: {module: ts.ModuleKind.CommonJS}}).outputText, {
  exports: result, moment, parseDateTimeFromUnixTime: value => ({getUnixTime: () => value}),
});
const inputs = [
  ['UTC', '2024-01-01', '2024-01-31', 1],
  ['UTC', '2024-02-01', '2024-02-29', -1],
  ['UTC', '2023-10-01', '2024-03-31', 1],
  ['UTC', '2023-07-15', '2024-07-14', 1],
  ['UTC', '2024-02-29', '2025-02-27', -1],
  ['UTC', '2024-01-31', '2024-02-28', 1],
  ['America/New_York', '2024-03-04', '2024-03-10', 1],
  ['America/New_York', '2024-10-28', '2024-11-03', -1],
  ['Asia/Hong_Kong', '2026-09-15', '2026-09-15', -1],
  ['Asia/Hong_Kong', '2026-09-15', '2026-09-19', 1],
];
const fixtures = inputs.map(([zone, start, end, scale]) => {
  moment.tz.setDefault(zone);
  const minTime = moment(start).startOf('day').unix();
  const maxTime = moment(end).endOf('day').unix();
  return {zone, minTime, maxTime, scale, expected: result.getShiftedDateRange(minTime, maxTime, scale)};
});
fs.writeFileSync(path.join(root, 'flutter_app/test/fixtures/web_statistics_ranges.json'), JSON.stringify(fixtures, null, 2) + '\n');
console.log(`Generated ${fixtures.length} original Web statistics range fixtures`);
