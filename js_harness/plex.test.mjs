// Live validation of the bundled Plex Watch source: anonymous token, free
// AVOD catalog, episodes and stream URLs. No sign-in or Plex Pass involved.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callProvider, loadProvider } from './host.mjs';

const id = 'clearcut_plex';
loadProvider(id, new URL('../assets/builtin_sources/plex.js', import.meta.url));
const call = async (m, ...a) => JSON.parse(await callProvider(id, m, a));

test('Plex reports a movie source and serves a catalog', { timeout: 90000 }, async () => {
  const info = await call('getInfo');
  assert.equal(info.type, 'movie');
  const popular = await call('popular', { page: 1 });
  assert.ok(Array.isArray(popular) && popular.length > 0, 'popular rail');
  assert.match(popular[0].url, /^plex:\/\/(movie|tv)\/[a-f0-9]{24}$/);
});

test('search finds an AVOD movie and resolves a playable HLS link', { timeout: 90000 }, async () => {
  const found = await call('search', 'dog soldiers', 1, {});
  const movie = found.find(x => /dog soldiers/i.test(x.title));
  assert.ok(movie, 'Dog Soldiers in search results');

  const detail = await call('getDetail', movie.url, {});
  assert.equal(detail.type, 'movie');
  assert.ok(detail.episodes.length >= 1);
  const streams = await call('getVideoSources', detail.episodes[0].url, true);
  assert.ok(streams.length > 0, 'real stream');
  assert.match(streams[0].url, /^https:\/\/vod\.provider\.plex\.tv\/library\/parts\/.*X-Plex-Token=/);
});

test('anime shelf resolves episodes and stream links', { timeout: 90000 }, async () => {
  const shelf = await call('getHomePage', 'anime', 1, {});
  const show = shelf.find(x => x.type === 'tv' && x.url.startsWith('plex://tv/'));
  assert.ok(show, 'free VOD show in the anime shelf');
  const episodes = await call('getEpisodes', show.url, {});
  assert.ok(episodes.length > 0, 'episode list');
  assert.match(episodes[0].url, /^plex:\/\/tv\/[a-f0-9]{24}\/\d+\/\d+\/[a-f0-9]{24}$/);
  const streams = await call('getVideoSources', episodes[0].url, true);
  assert.ok(streams.length > 0, 'playable anime episode');
});
