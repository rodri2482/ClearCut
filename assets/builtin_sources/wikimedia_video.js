// ClearCut built-in video source: Wikimedia Commons.
// Public-domain and freely licensed films, animation, short films and
// newsreels hosted by the Wikimedia Foundation (https://commons.wikimedia.org).
// Each file keeps its own licence; the detail page shows it with the author.
// Plays Commons' own transcodes (240p–2160p WebM/VP9) and the original file.
//
// Be gentle with Wikimedia's API (it rate-limits bursts): one request per home
// row, video details fetched together with the search, results cached, and one
// retry on HTTP 429.

var SOURCE_ID = 'clearcut_wikimedia';
var API = 'https://commons.wikimedia.org/w/api.php';
var SITE = 'https://commons.wikimedia.org';
var UA = 'ClearCut/1.0 (open-source media player)';

// Commons names each transcode by its standard size ("…1080p.vp9.webm") even
// for widescreen films whose real height is 804 px; use that name.
function _label(d) {
  var m = String(d.src || '').match(/\.(\d{3,4})p\.(?:vp9|vp8)\.webm$/i);
  return (m ? m[1] : d.height) + 'p';
}

function getInfo() {
  return { name: 'Wikimedia Commons (free films)', lang: 'en', baseUrl: SITE,
           logo: SITE + '/static/favicon/commons.ico', type: 'movie', version: '1.0.0' };
}

var _cache = {}; // file title -> page object (with videoinfo)

function _getJsonOnce(url) {
  return fetch(url, { headers: { 'Accept': 'application/json', 'User-Agent': UA, 'Api-User-Agent': UA } })
    .then(function (r) {
      if (r.status === 429) throw new Error('RATE');
      if (!r.ok) throw new Error('Wikimedia: HTTP ' + r.status);
      try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('Wikimedia: bad JSON'); }
    });
}

function _getJson(url) {
  return _getJsonOnce(url).catch(function () { return _getJsonOnce(url); });
}

function _query(params) {
  var base = {
    action: 'query', format: 'json', formatversion: '2',
    prop: 'videoinfo', viprop: 'url|size|mime|derivatives|extmetadata',
    viurlwidth: '480', origin: '*',
  };
  var all = {};
  var k;
  for (k in base) all[k] = base[k];
  for (k in params) all[k] = params[k];
  var qs = Object.keys(all).map(function (key) {
    return encodeURIComponent(key) + '=' + encodeURIComponent(all[key]);
  }).join('&');
  return _getJson(API + '?' + qs).then(function (d) {
    var pages = (d && d.query && d.query.pages) || [];
    pages.forEach(function (p) { if (p.videoinfo) _cache[p.title] = p; });
    // Search results come back unordered; keep the search ranking.
    pages.sort(function (a, b) { return (a.index || 0) - (b.index || 0); });
    return pages.filter(function (p) { return p.videoinfo && p.videoinfo.length; });
  });
}

function _meta(p, key) {
  var em = (p.videoinfo[0].extmetadata || {})[key];
  return em && em.value ? String(em.value).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '';
}

function _cleanTitle(t) {
  return String(t).replace(/^File:/, '').replace(/\.(webm|ogv|ogg|mp4|mpg|mpeg)$/i, '')
    .replace(/[_]+/g, ' ').trim();
}

function _item(p) {
  return {
    id: p.title,
    title: _cleanTitle(p.title),
    url: SITE + '/wiki/' + encodeURIComponent(p.title.replace(/ /g, '_')),
    cover: p.videoinfo[0].thumburl,
    type: 'movie',
    sourceId: SOURCE_ID,
  };
}

function _search(q, page) {
  return _query({
    generator: 'search', gsrnamespace: '6', gsrlimit: '30',
    gsroffset: String(((page || 1) - 1) * 30), gsrsearch: q,
  }).then(function (pages) { return pages.map(_item); });
}

var ROWS = [
  { id: 'films', title: 'Public-domain films', q: 'filetype:video incategory:Films_in_the_public_domain|Feature_films|Silent_films' },
  { id: 'animation', title: 'Animation', q: 'filetype:video incategory:Animated_films' },
  { id: 'shorts', title: 'Short films', q: 'filetype:video incategory:Short_films' },
  { id: 'history', title: 'Newsreels & history', q: 'filetype:video incategory:Newsreels' },
];

function getHome(opts) {
  // Sequential on purpose: four parallel bursts are what trips the rate limit.
  var rows = [];
  var chain = Promise.resolve();
  ROWS.forEach(function (row) {
    chain = chain.then(function () {
      return _search(row.q, 1).then(
        function (items) { if (items.length) rows.push({ id: row.id, title: row.title, items: items }); },
        function () {}
      );
    });
  });
  return chain.then(function () { return rows; });
}

function getHomePage(rowId, page, opts) {
  for (var i = 0; i < ROWS.length; i++) {
    if (ROWS[i].id === rowId) return _search(ROWS[i].q, page);
  }
  return [];
}

function popular(opts) {
  return _search(ROWS[0].q, (opts && opts.page) || 1);
}

function search(query, page, opts) {
  return _search('filetype:video ' + String(query || ''), page);
}

function _titleFromUrl(url) {
  var s = String(url);
  try { s = decodeURIComponent(s); } catch (e) {}
  var m = s.match(/\/wiki\/(File:[^?#]+)/);
  return (m ? m[1] : s).replace(/_/g, ' ');
}

function _page(title) {
  if (_cache[title]) return Promise.resolve(_cache[title]);
  return _query({ titles: title }).then(function (pages) {
    if (!pages.length) throw new Error('Wikimedia: file not found');
    return pages[0];
  });
}

function getDetail(url) {
  var title = _titleFromUrl(url);
  return _page(title).then(function (p) {
    var it = _item(p);
    var licence = _meta(p, 'LicenseShortName');
    var artist = _meta(p, 'Artist');
    var desc = _meta(p, 'ImageDescription');
    var credit = [artist && ('By ' + artist), licence && ('Licence: ' + licence)]
      .filter(Boolean).join(' · ');
    var date = _meta(p, 'DateTimeOriginal');
    var year = (date.match(/\b(1[89]\d\d|20\d\d)\b/) || [])[1];
    return {
      id: p.title,
      title: it.title,
      url: it.url,
      cover: it.cover,
      description: [desc, credit].filter(Boolean).join('\n\n'),
      status: 'completed',
      genres: _meta(p, 'Categories').split('|').map(function (c) { return c.trim(); })
        .filter(function (c) { return c && c.length < 40; }).slice(0, 5),
      studios: artist ? [artist.substring(0, 60)] : [],
      year: year,
      type: 'movie',
      sourceId: SOURCE_ID,
      episodes: [{ id: p.title, title: it.title, number: 1, url: p.title }],
    };
  });
}

function getEpisodes(seriesUrl) {
  var title = _titleFromUrl(seriesUrl);
  return [{ id: title, title: 'Video', number: 1, url: title }];
}

function _streams(p) {
  var vi = p.videoinfo[0];
  var out = [];
  (vi.derivatives || []).forEach(function (d) {
    var type = String(d.type || '');
    // WebM transcodes play everywhere; Commons' MPEG-4 Part 2 .mov ones don't.
    if (type.indexOf('webm') < 0 || !d.height) return;
    out.push({ url: d.src, quality: _label(d), label: 'Commons · ' + _label(d) + ' WebM',
               container: 'unknown', kind: 'unknown' });
  });
  out.sort(function (a, b) { return parseInt(b.quality, 10) - parseInt(a.quality, 10); });
  if (vi.url) {
    out.push({ url: vi.url, quality: 'Original',
               label: 'Original file' + (vi.size ? ' · ' + Math.round(vi.size / 1048576) + ' MB' : ''),
               container: /\.mp4$/i.test(vi.url) ? 'mp4' : 'unknown', kind: 'unknown' });
  }
  return out;
}

function getVideoSources(episodeUrl) {
  return _page(_titleFromUrl(episodeUrl)).then(_streams);
}
