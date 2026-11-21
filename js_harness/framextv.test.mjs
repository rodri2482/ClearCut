import { test } from 'node:test';
import assert from 'node:assert/strict';
import { callProvider, loadProvider } from './host.mjs';

const id = 'clearcut_framextv';
loadProvider(id, new URL('../assets/builtin_sources/framextv.js', import.meta.url));
const movie = { id: 42, type: 'movie', title: 'Same ID' };
const tv = { id: 42, type: 'tv', title: 'Same ID' };
const anime = { id: 42, type: 'anime', title: 'Same ID' };
const requests = [];

globalThis.__fetch = async (_, url) => {
  const u = new URL(url);
  requests.push(u);
  const query = u.searchParams;
  let data;
  if (u.pathname === '/api/home') {
    data = { rails: { popular_movies: { results: [movie] }, popular_tv: { results: [tv] }, popular_anime: { results: [anime] } } };
  } else if (u.pathname.endsWith('/search')) {
    data = { results: u.pathname.startsWith('/anime') ? [anime] : [movie, tv] };
  } else if (u.pathname.endsWith('/details')) {
    data = u.pathname.startsWith('/anime')
      ? { ...anime, episodes: 2 }
      : { ...tv, seasons: [{ season_number: 2, episode_count: 6 }] };
  } else if (u.pathname === '/api/season') {
    data = { episodes: [{ episode_number: 4, name: 'The Fourth' }] };
  } else if (u.pathname.endsWith('/stream')) {
    data = {
      success: true,
      headers: { Referer: 'https://source.example/', Cookie: 'must not forward' },
      sources: [
        { url: 'https://media.example/manifest', type: 'hls', server: 'Mirror A' },
        { url: 'https://media.example/embed/42', type: 'iframe' },
      ],
      subtitles: [{ url: 'https://media.example/en.vtt', lang: 'en', isDefault: true }],
    };
  } else {
    assert.fail('Unexpected endpoint ' + u.pathname);
  }
  return { ok: true, body: JSON.stringify({ success: true, ...data }) };
};

const call = async (method, ...args) => JSON.parse(await callProvider(id, method, args));

test('catalog and search preserve separate movie, TV and anime identities', async () => {
  const rows = await call('getHome');
  assert.equal(rows.length, 3);
  const results = await call('search', 'same & id', 1, {});
  assert.equal(new Set(results.map(item => item.url)).size, 3);
  assert.equal(requests.find(request => request.pathname === '/api/search').searchParams.get('q'), 'same & id');
});

test('TV playback uses actual episode numbers and hands native mirrors to ClearCut', async () => {
  const detail = await call('getDetail', 'framextv://tv/42');
  assert.equal(detail.tmdbIsTv, true);
  assert.equal(detail.episodes.length, 1);
  assert.match(detail.episodes[0].title, /^S2 E4/);
  const sources = await call('getVideoSources', detail.episodes[0].url);
  const request = requests.at(-1);
  assert.equal(request.searchParams.get('season'), '2');
  assert.equal(request.searchParams.get('episode'), '4');
  assert.deepEqual(sources.map(s => s.container), ['hls']);
  assert.equal(sources[0].headers.Referer, 'https://source.example/');
  assert.equal(sources[0].headers.Cookie, undefined);
  assert.equal(sources[0].subtitles[0].default, true);
});

test('anime playback routes by AniList ID to the separate anime API', async () => {
  const detail = await call('getDetail', 'framextv://anime/42');
  assert.equal(detail.episodes.length, 2);
  await call('getVideoSources', detail.episodes[1].url);
  const request = requests.at(-1);
  assert.equal(request.pathname, '/anime/api/stream');
  assert.equal(request.searchParams.get('id'), '42');
  assert.equal(request.searchParams.get('episode'), '2');
});
