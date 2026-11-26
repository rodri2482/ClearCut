// Live validation of the bundled WEBTOON source against the real site.
// Uses the pure-Node host that mirrors ClearCut's JS bootstrap/fetch contract.
// Run: node --test js_harness/webtoon.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callProvider, loadProvider } from './host.mjs';

const id = 'clearcut_webtoon';
loadProvider(id, new URL('../assets/builtin_sources/webtoon.js', import.meta.url));

const call = async (method, ...args) =>
  JSON.parse(await callProvider(id, method, args));

test('WEBTOON reports itself as a manga source', async () => {
  const info = await call('getInfo');
  assert.equal(info.type, 'manga');
  assert.equal(info.name, 'WEBTOON');
});

test('catalog and search return real series from the live site', { timeout: 90000 }, async () => {
  const popular = await call('popular', { page: 1 });
  assert.ok(Array.isArray(popular) && popular.length > 0, 'popular shelf');
  assert.match(popular[0].url, /title_no=\d+/);
  assert.equal(popular[0].type, 'manga');

  const found = await call('search', 'witch', 1, {});
  assert.ok(Array.isArray(found) && found.length > 0, 'search results');
  assert.match(found[0].url, /webtoons\.com\/en\//);
  assert.ok(found[0].title && found[0].title.length > 0);
});

test('series detail exposes chapters with exact viewer URLs', { timeout: 90000 }, async () => {
  const found = await call('search', 'witch', 1, {});
  const url = found[0].url;
  const detail = await call('getDetail', url, {});
  assert.equal(detail.type, 'manga');
  assert.ok(detail.title);
  assert.ok(Array.isArray(detail.chapters) && detail.chapters.length > 0);
  // The slug is part of the route: a bare /viewer?title_no=... 404s.
  assert.match(detail.chapters[0].url, /\/viewer\?title_no=\d+&episode_no=\d+/);
  assert.ok(detail.chapters[0].number > 0);

  const chapters = await call('getEpisodes', url, {});
  assert.ok(chapters.length > 0, 'paginated chapter list');
  assert.equal(chapters[0].number, Math.max(...chapters.map((c) => c.number)));
});

test('getPages returns the episode panels, not recommendation thumbnails', { timeout: 90000 }, async () => {
  const found = await call('search', 'witch', 1, {});
  const detail = await call('getDetail', found[0].url, {});
  const pages = await call('getPages', detail.chapters[0].url);
  assert.ok(Array.isArray(pages) && pages.length > 0, 'page list');
  for (const page of pages.slice(0, 5)) {
    assert.match(page.url, /^https:\/\/[^\s]+\.pstatic\.net\//);
    assert.equal(page.headers.Referer, 'https://www.webtoons.com/');
  }
});
