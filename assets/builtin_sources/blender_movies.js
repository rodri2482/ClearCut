// ClearCut built-in video source: Blender Open Movies.
// The animated films made by the Blender Foundation / Blender Studio and
// released under Creative Commons licences (https://studio.blender.org/films).
// Video and posters come from Wikimedia Commons (several qualities, up to 4K);
// Blender's own download server is added as a mirror where it has a playable
// file. Every film's page credits Blender and names its licence, as the
// licences require.

var SOURCE_ID = 'clearcut_blender';
var API = 'https://commons.wikimedia.org/w/api.php';
var SITE = 'https://studio.blender.org/films/';
var UA = 'ClearCut/1.0 (open-source media player)';
var CREDIT = '© Blender Foundation / Blender Studio — blender.org';

// Curated list. Descriptions are ClearCut's own one-line summaries.
var FILMS = [
  { id: 'elephants-dream', title: 'Elephants Dream', year: '2006',
    file: 'File:Elephants Dream (2006).webm', licence: 'CC BY 2.5',
    about: 'Two men explore a strange, ever-shifting machine world — the very first open movie.',
    mirrors: [
      { url: 'https://download.blender.org/ED/elephantsdream-720-h264-st-aac.mov', quality: '720p' },
      { url: 'https://download.blender.org/ED/elephantsdream-480-h264-st-aac.mov', quality: '480p' },
    ] },
  { id: 'big-buck-bunny', title: 'Big Buck Bunny', year: '2008',
    file: 'File:Big Buck Bunny 4K.webm', licence: 'CC BY 3.0',
    about: 'A gentle giant rabbit takes comic revenge on three bullying rodents.' },
  { id: 'sintel', title: 'Sintel', year: '2010',
    file: 'File:Sintel movie 4K.webm', licence: 'CC BY 3.0',
    about: 'A lone girl searches far and wide for the baby dragon she once rescued.',
    mirrors: [{ url: 'https://download.blender.org/durian/movies/Sintel.2010.1080p.mkv', quality: '1080p' }] },
  { id: 'tears-of-steel', title: 'Tears of Steel', year: '2012',
    file: 'File:Tears of Steel in 4k - Official Blender Foundation release.webm', licence: 'CC BY 3.0',
    about: 'Live action meets visual effects as scientists try to save the world from robots.',
    mirrors: [{ url: 'https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov', quality: '720p' }] },
  { id: 'caminandes-llama-drama', title: 'Caminandes: Llama Drama', year: '2013',
    file: 'File:Caminandes- Llama Drama - Short Movie.ogv', licence: 'CC BY 3.0',
    about: 'Koro the llama wants to cross a fenced road in Patagonia.' },
  { id: 'caminandes-gran-dillama', title: 'Caminandes: Gran Dillama', year: '2013',
    file: "File:Caminandes - Gran Dillama - Blender Foundation's new Open Movie.webm", licence: 'CC BY 3.0',
    about: 'Koro the llama tries once more to get past an electric fence.' },
  { id: 'cosmos-laundromat', title: 'Cosmos Laundromat', year: '2015',
    file: 'File:Cosmos Laundromat - First Cycle - Official Blender Foundation release.webm', licence: 'CC BY 4.0',
    about: 'A suicidal sheep meets a mysterious salesman who offers him a lifetime of lives.' },
  { id: 'caminandes-llamigos', title: 'Caminandes 3: Llamigos', year: '2016',
    file: 'File:Caminandes 3 - Llamigos - Blender Animated Short.webm', licence: 'CC BY 4.0',
    about: 'Koro the llama meets a hungry penguin in the snowy Andes.' },
  { id: 'hero', title: 'Hero', year: '2018',
    file: 'File:HERO - Blender Open Movie-full movie.webm', licence: 'CC BY 4.0',
    about: 'A short showcase of 2D animation drawn in 3D with Grease Pencil.' },
  { id: 'spring', title: 'Spring', year: '2019',
    file: 'File:Spring - Blender Open Movie.webm', licence: 'CC BY 4.0',
    about: 'A shepherd girl and her dog face ancient spirits to bring back the spring.' },
  { id: 'coffee-run', title: 'Coffee Run', year: '2020',
    file: 'File:Coffee Run - Blender Open Movie-full movie.webm', licence: 'CC BY 4.0',
    about: 'A caffeine-fuelled dash through memories of love and loss.' },
  { id: 'sprite-fright', title: 'Sprite Fright', year: '2021',
    file: 'File:Sprite Fright - Blender Open Movie-full movie.webm', licence: 'CC BY 4.0',
    about: 'Teenagers on a forest trip meet adorable woodland sprites — with a dark side.' },
  { id: 'charge', title: 'Charge', year: '2022',
    file: 'File:Charge - Blender Open Movie-full movie.webm', licence: 'CC BY 4.0',
    about: 'In an energy-starved future, an old man breaks into a battery factory.' },
  { id: 'wing-it', title: 'Wing It!', year: '2023',
    file: 'File:WING IT! - Blender Open Movie-full movie.webm', licence: 'CC BY 4.0',
    about: 'A cat and a dog build a rocket from junk — what could go wrong?' },
];

// Commons names each transcode by its standard size ("…1080p.vp9.webm") even
// for widescreen films whose real height is 804 px; use that name.
function _label(d) {
  var m = String(d.src || '').match(/\.(\d{3,4})p\.(?:vp9|vp8)\.webm$/i);
  return (m ? m[1] : d.height) + 'p';
}

function getInfo() {
  return { name: 'Blender Open Movies', lang: 'en', baseUrl: SITE,
           logo: 'https://www.blender.org/favicon.ico', type: 'movie', version: '1.0.0' };
}

var _pages = null; // file title -> Commons page (videoinfo), loaded once

function _getJsonOnce(url) {
  return fetch(url, { headers: { 'Accept': 'application/json', 'User-Agent': UA, 'Api-User-Agent': UA } })
    .then(function (r) {
      if (!r.ok) throw new Error('Wikimedia: HTTP ' + r.status);
      try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('Wikimedia: bad JSON'); }
    });
}

function _getJson(url) {
  return _getJsonOnce(url).catch(function () { return _getJsonOnce(url); });
}

// One batched request for every film (Commons allows 50 titles per call).
function _load() {
  if (_pages) return Promise.resolve(_pages);
  var params = {
    action: 'query', format: 'json', formatversion: '2', origin: '*',
    prop: 'videoinfo', viprop: 'url|size|derivatives', viurlwidth: '640',
    titles: FILMS.map(function (f) { return f.file; }).join('|'),
  };
  var qs = Object.keys(params).map(function (k) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
  }).join('&');
  return _getJson(API + '?' + qs).then(function (d) {
    var map = {};
    var norm = {};
    ((d && d.query && d.query.normalized) || []).forEach(function (n) { norm[n.to] = n.from; });
    ((d && d.query && d.query.pages) || []).forEach(function (p) {
      if (p.videoinfo && p.videoinfo.length) map[norm[p.title] || p.title] = p;
    });
    _pages = map;
    return map;
  });
}

function _film(id) {
  var key = String(id).replace(/^.*\/films\//, '').replace(/[/?#].*$/, '');
  for (var i = 0; i < FILMS.length; i++) if (FILMS[i].id === key) return FILMS[i];
  return null;
}

function _item(f, pages) {
  var p = pages[f.file];
  return {
    id: f.id, title: f.title, url: SITE + f.id,
    cover: p ? p.videoinfo[0].thumburl : undefined,
    type: 'movie', sourceId: SOURCE_ID,
  };
}

function getHome(opts) {
  return _load().then(function (pages) {
    var all = FILMS.map(function (f) { return _item(f, pages); });
    var newest = all.slice().reverse();
    return [
      { id: 'newest', title: 'Blender Open Movies — newest first', items: newest },
      { id: 'classics', title: 'The classics', items: all.slice(0, 5) },
      { id: 'caminandes', title: 'Caminandes llama shorts',
        items: all.filter(function (i) { return i.id.indexOf('caminandes') === 0; }) },
    ];
  });
}

function getHomePage(rowId, page, opts) { return []; }

function popular(opts) {
  if ((opts && opts.page) > 1) return [];
  return _load().then(function (pages) {
    return FILMS.map(function (f) { return _item(f, pages); });
  });
}

function search(query, page, opts) {
  if (page > 1) return [];
  var q = String(query || '').toLowerCase().trim();
  return _load().then(function (pages) {
    return FILMS.filter(function (f) {
      return !q || f.title.toLowerCase().indexOf(q) >= 0 || f.about.toLowerCase().indexOf(q) >= 0 ||
        q.indexOf('blender') >= 0;
    }).map(function (f) { return _item(f, pages); });
  });
}

function getDetail(url) {
  var f = _film(url);
  if (!f) return Promise.reject(new Error('Blender: film not found'));
  return _load().then(function (pages) {
    return {
      id: f.id, title: f.title, url: SITE + f.id,
      cover: _item(f, pages).cover,
      description: f.about + '\n\n' + CREDIT + ' · Licence: ' + f.licence,
      status: 'completed',
      genres: ['Animation', 'Short film', 'Open movie'],
      studios: ['Blender Studio'],
      year: f.year,
      type: 'movie', sourceId: SOURCE_ID,
      episodes: [{ id: f.id, title: f.title, number: 1, url: f.id }],
    };
  });
}

function getEpisodes(seriesUrl) {
  var f = _film(seriesUrl);
  return f ? [{ id: f.id, title: f.title, number: 1, url: f.id }] : [];
}

function getVideoSources(episodeUrl) {
  var f = _film(episodeUrl);
  if (!f) return [];
  return _load().then(function (pages) {
    var out = [];
    var p = pages[f.file];
    if (p) {
      var vi = p.videoinfo[0];
      (vi.derivatives || []).forEach(function (d) {
        if (String(d.type || '').indexOf('webm') < 0 || !d.height) return;
        out.push({ url: d.src, quality: _label(d), label: 'Commons · ' + _label(d),
                   container: 'unknown', kind: 'unknown' });
      });
      out.sort(function (a, b) { return parseInt(b.quality, 10) - parseInt(a.quality, 10); });
    }
    (f.mirrors || []).forEach(function (m) {
      out.push({ url: m.url, quality: m.quality, label: 'blender.org · ' + m.quality,
                 container: 'unknown', kind: 'unknown' });
    });
    if (p && p.videoinfo[0].url) {
      out.push({ url: p.videoinfo[0].url, quality: 'Original', label: 'Original file',
                 container: 'unknown', kind: 'unknown' });
    }
    return out;
  });
}
