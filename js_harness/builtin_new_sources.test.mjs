import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadProvider, callProvider } from './host.mjs';

// Contract smoke test for the two new legal built-ins. The network is stubbed
// so the test never depends on an instance staying up.
const ptVideo = {
  uuid: 'abc-123',
  name: 'A free documentary',
  thumbnailPath: '/lazy-static/thumb.jpg',
  thumbnails: [{ fileUrl: 'https://peertube.tv/thumb.jpg' }],
  description: 'A description',
  publishedAt: '2025-01-01T00:00:00Z',
  tags: ['science'],
  channel: { displayName: 'A channel' },
  streamingPlaylists: [{ playlistUrl: 'https://cdn.example/master.m3u8' }],
  files: [
    {
      fileUrl: 'https://cdn.example/video-1080.mp4',
      resolution: { label: '1080p' },
      size: 1000,
      hasVideo: true,
    },
  ],
};

const ovTrack = {
  id: 'track-1',
  title: 'Ambient Flight',
  creator: 'Zeropage',
  license: 'by',
  url: 'https://cdn.example/track.mp3',
  thumbnail: 'https://example.com/thumb.jpg',
  genres: ['ambient'],
};

globalThis.__fetch = async (_sourceId, url, _opts) => {
  const u = String(url);
  let data;
  if (u.includes('api.tvmaze')) data = null;
  else if (u.includes('api.openverse.org/v1/audio/')) {
    data = u.endsWith('/track-1/') || u.includes('%3A')
      ? ovTrack
      : { results: [ovTrack] };
  } else if (u.includes('/api/v1/videos/') && !u.includes('?')) {
    data = ptVideo;
  } else if (u.includes('/api/v1/videos?')) {
    data = { data: [ptVideo] };
  } else {
    data = null;
  }
  const body = JSON.stringify(data);
  return {
    ok: true,
    status: 200,
    statusText: 'OK',
    headers: {},
    url: u,
    body,
    text: () => body,
    json: () => data,
  };
};

loadProvider(
  'clearcut_peertube',
  new URL('../assets/builtin_sources/peertube_video.js', import.meta.url),
);
loadProvider(
  'clearcut_openverse',
  new URL('../assets/builtin_sources/openverse_audio.js', import.meta.url),
);

test('PeerTube built-in lists federated videos and their HLS/MP4 files', async () => {
  const info = JSON.parse(await callProvider('clearcut_peertube', 'getInfo', []));
  assert.equal(info.type, 'movie');
  const rows = JSON.parse(
    await callProvider('clearcut_peertube', 'search', ['documentary', 1, {}]),
  );
  assert.ok(rows.length >= 1);
  assert.match(rows[0].url, /^peertube:\/\//);
  const detail = JSON.parse(
    await callProvider('clearcut_peertube', 'getDetail', [rows[0].url]),
  );
  assert.equal(detail.episodes.length, 1);
  const files = JSON.parse(
    await callProvider('clearcut_peertube', 'getVideoSources', [
      detail.episodes[0].url,
      true,
    ]),
  );
  assert.ok(files.some((f) => f.container === 'hls'));
  assert.ok(files.some((f) => f.url.endsWith('.mp4')));
});

test('Openverse built-in lists CC audio with a direct file URL', async () => {
  const rows = JSON.parse(
    await callProvider('clearcut_openverse', 'search', ['ambient', 1, {}]),
  );
  assert.equal(rows[0].title, 'Ambient Flight');
  const files = JSON.parse(
    await callProvider('clearcut_openverse', 'getVideoSources', [rows[0].url]),
  );
  assert.equal(files[0].url, 'https://cdn.example/track.mp3');
  assert.match(files[0].label, /Zeropage/);
});
