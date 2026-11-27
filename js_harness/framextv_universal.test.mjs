// Live check that FrameXTV's bundled source resolves an arbitrary TMDB /
// AniList ID, not only titles found in its own catalog. This is the contract
// the app's universal final fallback relies on.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callProvider, loadProvider } from './host.mjs';

const id = 'clearcut_framextv';
loadProvider(id, new URL('../assets/builtin_sources/framextv.js', import.meta.url));
const call = async (m, ...a) => JSON.parse(await callProvider(id, m, a));

test('a raw TMDB movie id resolves to episodes and streams', { timeout: 90000 }, async () => {
  const url = 'framextv://movie/550';
  const detail = await call('getDetail', url, {});
  assert.equal(detail.type, 'movie');
  assert.ok(detail.episodes.length >= 1);
  const streams = await call('getVideoSources', detail.episodes[0].url, true);
  assert.ok(streams.length > 0, 'at least one real stream');
  assert.match(streams[0].url, /^https:\/\//);
});

test('a raw AniList anime id resolves to episodes and streams', { timeout: 90000 }, async () => {
  const url = 'framextv://anime/5114/1/1';
  const detail = await call('getDetail', url, {});
  assert.equal(detail.type, 'anime');
  assert.ok(detail.episodes.length >= 1);
  const streams = await call('getVideoSources', detail.episodes[0].url, true);
  assert.ok(streams.length > 0, 'at least one real stream');
});
