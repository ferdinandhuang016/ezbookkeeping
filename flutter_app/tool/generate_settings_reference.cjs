// Export the same option values and defaults used by the original mobile pages.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
function readModule(filename) {
  filename = path.resolve(filename);
  if (cache.has(filename)) return cache.get(filename);
  if (filename.endsWith('.json')) return JSON.parse(fs.readFileSync(filename, 'utf8'));
  const exports = {}; cache.set(filename, exports);
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  vm.runInNewContext(source, {exports, require:name=>readModule(name.startsWith('@/')?path.join(root,'src',name.slice(2)):path.resolve(path.dirname(filename),name))}, {filename});
  return exports;
}
const data = {options:{}};
for (const file of ['calendar','datetime','fiscalyear','numeral','currency','coordinate','account','transaction','image','text','timezone']) {
  const module = readModule(path.join(root,`src/core/${file}.ts`));
  for (const [name, type] of Object.entries(module)) {
    if (typeof type === 'function' && typeof type.values === 'function') {
      try { data.options[name] = (name === 'TransactionEditScopeType' ? type.values(true) : type.values()).map(item=>({...item,id:item.type ?? item.value,name:item.name ?? item.typeName ?? String(item.type)})); } catch (_) {}
    }
  }
}
const setting = readModule(path.join(root,'src/core/setting.ts'));
data.defaults = setting.DEFAULT_APPLICATION_SETTINGS;
const zones = readModule(path.join(root,'src/core/timezone.ts')).TimezoneTypeForStatistics;
data.options.TimezoneTypeForStatistics = [zones.ApplicationTimezone,zones.TransactionTimezone].map(item=>({...item,id:item.type}));
data.cloudTypes = setting.ALL_ALLOWED_CLOUD_SYNC_APP_SETTING_KEY_TYPES;
const cloudSource = fs.readFileSync(path.join(root,'src/views/base/settings/AppCloudSyncPageBase.ts'),'utf8');
const cloudLiteral = cloudSource.match(/export const ALL_APPLICATION_CLOUD_SETTINGS[^=]+=(\s*\[[\s\S]*?\n\]);/)[1];
data.cloudGroups = vm.runInNewContext('('+cloudLiteral+')');
data.timezones = readModule(path.join(root,'src/consts/timezone.ts')).ALL_TIMEZONES;
data.languages = Object.entries(readModule(path.join(root,'src/locales/index.ts')).ALL_LANGUAGES).map(([id,item])=>({id,name:item.displayName}));
data.chartColors = readModule(path.join(root,'src/consts/color.ts')).DEFAULT_CHART_COLORS;
fs.writeFileSync(path.join(root,'flutter_app/assets/reference/settings.json'),JSON.stringify(data,null,2)+'\n');
fs.copyFileSync(path.join(root,'LICENSE'),path.join(root,'flutter_app/assets/reference/LICENSE.txt'));
fs.copyFileSync(path.join(root,'contributors.json'),path.join(root,'flutter_app/assets/reference/contributors.json'));
fs.copyFileSync(path.join(root,'third-party-dependencies.json'),path.join(root,'flutter_app/assets/reference/web_licenses.json'));
console.log(`Generated ${Object.keys(data.options).length} option groups and ${Object.keys(data.cloudTypes).length} cloud setting definitions.`);
