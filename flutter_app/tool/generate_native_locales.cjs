// Native-only additions. Existing Web locale assets are read, never rewritten.
// Update native_messages.psv (one key and 20 translations per row) or aliases,
// then run: node tool/generate_native_locales.cjs
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const locales = 'de el es fr it ja kn ko nl pt_BR ro ru sl ta th tr uk vi zh_Hans zh_Hant'.split(' ');
const aliases = JSON.parse(fs.readFileSync(path.join(__dirname, 'native_locale_aliases.json')));
const all = Object.fromEntries(['en', ...locales].map(locale => [locale, {}]));
const placeholders = value => [...value.matchAll(/\{\w+\}/g)].map(match => match[0]).sort().join(',');
const source = Object.fromEntries(Object.keys(all).map(locale => [locale,
  JSON.parse(fs.readFileSync(path.join(root, `assets/locales/${locale}.json`)))]));
for (const [index, raw] of fs.readFileSync(path.join(__dirname, 'native_messages.psv'), 'utf8').split(/\r?\n/).entries()) {
  const line = raw.replace(/^\uFEFF/, '');
  if (!line || line.startsWith('#')) continue;
  const [key, ...values] = line.split('|');
  if (values.length !== locales.length || values.some(value => !value.trim())) {
    throw Error(`native_messages.psv:${index + 1}: expected ${locales.length} nonempty translations, got ${values.length}`);
  }
  if (key in all.en || key in aliases) throw Error(`Duplicate native key: ${key}`);
  all.en[key] = key;
  locales.forEach((locale, i) => {
    if (placeholders(key) !== placeholders(values[i])) throw Error(`Placeholder mismatch: ${locale}: ${key}`);
    all[locale][key] = values[i];
  });
}
function lookup(map, key) {
  return map[key] ?? key.split('.').reduce((value, part) => value?.[part], map);
}
for (const [key, reference] of Object.entries(aliases)) {
  for (const locale of Object.keys(all)) {
    const value = lookup(source[locale], reference) ?? all[locale][reference];
    if (typeof value !== 'string') throw Error(`Unknown alias: ${locale}: ${key} -> ${reference}`);
    all[locale][key] = value;
  }
}
const target = path.join(root, 'assets/native_locales');
const check = process.argv.includes('--check');
if (check) {
  const known = new Set(Object.keys(all.en));
  function collectKeys(map, prefix = '') {
    for (const [key, value] of Object.entries(map)) {
      if (typeof value === 'string') {
        known.add(key);
        known.add(prefix + key);
      } else if (value && typeof value === 'object') collectKeys(value, `${prefix}${key}.`);
    }
  }
  collectKeys(source.en);
  for (const file of fs.readdirSync(path.join(root, 'lib'), { recursive: true }).filter(file => file.endsWith('.dart'))) {
    const text = fs.readFileSync(path.join(root, 'lib', file), 'utf8');
    const literal = /\b(?:t|tr|StateError|FormatException)\(\s*(['"])((?:\\.|(?!\1)[^\\])*?)\1/g;
    for (const match of text.matchAll(literal)) {
      const key = match[2].replace(/\\(['"\\])/g, '$1');
      if (!key.includes('$') && !known.has(key)) throw Error(`Untranslated literal in lib/${file}: ${key}`);
    }
  }
}
if (!check) fs.mkdirSync(target, { recursive: true });
for (const [locale, entries] of Object.entries(all)) {
  // Native additions must never overwrite an original root-level translation.
  const duplicate = Object.keys(entries).find(key => typeof source[locale][key] === 'string');
  if (duplicate) throw Error(`Native key already exists in Web locale: ${locale}: ${duplicate}`);
  const sorted = Object.fromEntries(Object.entries(entries).sort(([a], [b]) => a.localeCompare(b, 'en')));
  const output = JSON.stringify(sorted, null, 2) + '\n';
  const file = path.join(target, `${locale}.json`);
  if (check) {
    if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== output) {
      throw Error(`Native locale is missing or stale: ${file}`);
    }
  } else {
    fs.writeFileSync(file, output);
  }
}
console.log(`${check ? 'Verified' : 'Generated'} ${Object.keys(all).length} native locales with ${Object.keys(all.en).length} keys each.`);
