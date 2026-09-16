// Original UAParser.js 1.x and presentation rules from src/lib/session.ts.
const fs = require('node:fs');
const path = require('node:path');
const parse = require('ua-parser-js');
const inputs = [
  ['Windows Chrome', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'],
  ['Mac Firefox', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0'],
  ['Linux Firefox', 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'],
  ['Android Phone', 'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36'],
  ['iPhone Safari', 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'],
  ['iPad Safari', 'Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'],
  ['Smart TV', 'Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) 85.0.4183.93/6.0 TV Safari/537.36'],
  ['Wearable', 'Mozilla/5.0 (Linux; Android 7.1.1; LG Watch Sport Build/NXH19X) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/57.0.2987.132 Mobile Safari/537.36'],
  ['Unknown', ''],
  ['API token', 'Automation token', 8],
  ['MCP token', 'Local MCP integration', 5],
];
const fixtures = inputs.map(([label, userAgent, tokenType = 1], index) => {
  const token = {userAgent, tokenType, tokenId: `${index + 1}`, isCurrent: index === 0};
  const parsed = parse(userAgent);
  let details = parsed.device.model || [parsed.os.name, parsed.os.version].filter(Boolean).join(' ');
  if (parsed.browser.name) {
    const browser = [parsed.browser.name, parsed.browser.version].filter(Boolean).join(' ');
    details = details ? `${details} (${browser})` : browser;
  }
  const deviceTypes = {mobile: 'phone', wearable: 'wearable', tablet: 'tablet', smarttv: 'tv'};
  return {label, token, expected: {
    name: tokenType === 8 ? 'API Token' : tokenType === 5 ? 'MCP Token' : token.isCurrent ? 'Current' : 'Other Device',
    details: tokenType === 8 || tokenType === 5 ? userAgent : details || 'Unknown Device',
    device: tokenType === 8 ? 'api' : tokenType === 5 ? 'mcp' : deviceTypes[parsed.device.type] || 'desktop',
  }};
});
fs.writeFileSync(path.join(__dirname, '../test/session_fixtures.json'), `${JSON.stringify(fixtures, null, 2)}\n`);
console.log(`Generated ${fixtures.length} original session fixtures`);
