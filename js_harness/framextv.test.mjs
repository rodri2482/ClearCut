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
  } else if (u.pathname.endsWith('/providers')) {
    data = query.get('sub_type') === 'dub' ? {
      providers: [{ id: 'dub_mirror', name: 'English Mirror', status: 'active', audio: 'dub' }],
    } : {
      providers: [
        { id: 'default', name: 'Default', status: 'available' },
        { id: 'alternate', name: 'Alternate', status: 'active' },
        { id: 'down', name: 'Offline', status: 'down' },
        { id: 'empty', name: 'Empty', status: 'available' },
      ],
    };
  } else if (u.pathname.endsWith('/stream')) {
    if (query.get('provider') === 'dub_mirror') {
      assert.equal(query.get('sub_type'), 'dub');
      return { ok: true, body: JSON.stringify({
        provider: 'dub_mirror',
        sources: [{ url: 'https://media.example/dub.mp4', type: 'mp4', audioLang: 'en' }],
      }) };
    }
    if (query.get('provider') === 'empty') {
      return { ok: false, status: 502 };
    }
    if (query.get('provider') === 'alternate') {
      return { ok: true, body: JSON.stringify({
        provider: 'alternate',
        sources: [
          { url: 'https://media.example/alternate.mp4', type: 'mp4' },
          { url: 'https://media.example/manifest', type: 'hls' },
        ],
      }) };
    }
    if (query.get('id') === '123' && !query.has('provider')) {
      return { ok: true, body: JSON.stringify({ success: false, alternates: ['alternate'] }) };
    }
    data = {
      success: true,
      provider: 'default',
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
  const sources = await call('getVideoSources', detail.episodes[0].url, true);
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
  await call('getVideoSources', detail.episodes[1].url, true);
  const request = requests.at(-1);
  assert.equal(request.pathname, '/anime/api/stream');
  assert.equal(request.searchParams.get('id'), '42');
  assert.equal(request.searchParams.get('episode'), '2');
});

test('the Sources menu resolves named servers and preserves exact TV episode parameters', async () => {
  const start = requests.length;
  const url = 'framextv://tv/42/2/4';
  const sources = await call('getVideoSources', url, false);
  assert.deepEqual(sources.map(s => s.label), ['Mirror A', 'Alternate']);
  assert.deepEqual(sources.map(s => s.container), ['hls', 'mp4']);
  const lookups = requests.slice(start);
  assert.deepEqual(lookups.filter(u => u.pathname.endsWith('/stream')).map(u => u.searchParams.get('provider')),
    ['alternate', 'empty']);
  assert.ok(lookups.filter(u => u.pathname.endsWith('/stream')).every(u =>
    u.searchParams.get('season') === '2' && u.searchParams.get('episode') === '4'));
  const beforeCached = requests.length;
  assert.deepEqual(await call('getVideoSources', url, false), sources);
  assert.equal(requests.length, beforeCached);
});

test('fast playback only expands to named servers when the default is empty', async () => {
  const start = requests.length;
  assert.deepEqual((await call('getVideoSources', 'framextv://movie/42', true)).map(s => s.label), ['Mirror A']);
  assert.equal(requests.length - start, 1);
  assert.ok((await call('getVideoSources', 'framextv://movie/123', true))
    .some(s => s.label === 'Alternate'));
  assert.ok(requests.slice(start + 1).some(u => u.searchParams.get('provider') === 'alternate'));
});

test('anime sources include a separate dub lookup and retain audio language', async () => {
  const all = await call('getVideoSources', 'framextv://anime/42/1/1', false);
  const dub = all.find(source => source.kind === 'dub');
  assert.equal(dub.label, 'English Mirror · Dub');
  assert.equal(dub.audioLang, 'en');
});
