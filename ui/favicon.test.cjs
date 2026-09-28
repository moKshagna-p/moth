const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { runInNewContext } = require('node:vm');
const script = readFileSync(`${__dirname}/favicon.js`, 'utf8');

function discover(links, page = 'https://example.com/page', base = page) {
  return runInNewContext(script, {
    URL,
    location: new URL(page),
    document: {
      baseURI: base,
      querySelectorAll: () => links.map(([rel, href]) => ({ rel, getAttribute: () => href })),
    },
  });
}

test('uses the actual icon ahead of touch icons and respects the document base URL', () => {
  const result = discover([
    ['apple-touch-icon', '/touch.png'],
    ['SHORTCUT ICON', 'brand.png'],
  ], 'https://example.com/page', 'https://cdn.example.com/assets/');
  assert.equal(result.icon, 'https://cdn.example.com/assets/brand.png');
  assert.equal(result.page, 'https://example.com/page');
});

test('skips unrelated, empty, malformed, and non-web icon links', () => {
  assert.equal(discover([
    ['stylesheet', '/styles.css'], ['icon', ''], ['icon', 'http://['],
    ['icon', 'file:///tmp/icon.png'], ['icon', 'https://user:pass@example.com/icon'],
    ['icon', '//cdn.example.com/favicon.ico'],
  ]).icon, 'https://cdn.example.com/favicon.ico');
});

test('falls back to touch icon, then the site origin favicon', () => {
  assert.equal(discover([['apple-touch-icon', '/touch.png']]).icon, 'https://example.com/touch.png');
  assert.equal(discover([], 'https://example.com/a/b?q=1#anchor').icon, 'https://example.com/favicon.ico');
});

test('blank tabs never request a favicon', () => {
  assert.equal(discover([], 'about:blank').icon, null);
});

test('a later discovery follows changed page metadata', () => {
  assert.equal(discover([['icon', '/first.png']]).icon, 'https://example.com/first.png');
  assert.equal(discover([['icon', '/updated.png']]).icon, 'https://example.com/updated.png');
});
