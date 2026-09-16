// Keep selector search equivalent to the original mobile NormalizedText helper.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../../node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const folded = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'src/consts/text.ts'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS },
}).outputText, { exports: folded });
const text = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'src/core/text.ts'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText, { exports: text, require: () => folded });
const characters = {};
for (let code = 0; code <= 0x10ffff; code++) {
  if (code >= 0xd800 && code <= 0xdfff) continue;
  const character = String.fromCodePoint(code);
  const normalized = text.NormalizedText.normalizeForSearch(character);
  if (normalized !== character) characters[character] = normalized;
}
fs.writeFileSync(path.join(root, 'flutter_app/assets/reference/search_characters.json'), JSON.stringify(characters) + '\n');
console.log(`Generated ${Object.keys(characters).length} original search character mappings.`);
