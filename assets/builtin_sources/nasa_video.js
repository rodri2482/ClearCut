// ClearCut built-in video source: NASA Image and Video Library.
// Space documentaries, launches, mission footage and science explainers from
// NASA's public API (https://images.nasa.gov). NASA media is generally not
// copyrighted (US government work); NASA's media usage guidelines apply.
// Plays NASA's own MP4 files (several sizes) with NASA's captions when present.

var SOURCE_ID = 'clearcut_nasa';
var API = 'https://images-api.nasa.gov';
var SITE = 'https://images.nasa.gov';

function getInfo() {
  return { name: 'NASA (free space videos)', lang: 'en', baseUrl: SITE,
           logo: 'https://www.nasa.gov/favicon.ico', type: 'movie', version: '1.0.0' };
}

function _getJsonOnce(url) {
  return fetch(url, { headers: { 'Accept': 'application/json' } }).then(function (r) {
    if (!r.ok) throw new Error('NASA: HTTP ' + r.status);
    try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('NASA: bad JSON'); }
  });
}

// One retry covers the occasional dropped request.
function _getJson(url) {
  return _getJsonOnce(url).catch(function () { return _getJsonOnce(url); });
}

function _https(u) { return String(u || '').replace(/^http:\/\//, 'https://'); }

function _item(it) {
  var d = (it.data && it.data[0]) || {};
  var thumb = (it.links || []).filter(function (l) { return l.render === 'image' || /\.(jpe?g|png)$/i.test(l.href); })[0];
  return {
    id: d.nasa_id,
    title: d.title || d.nasa_id,
    url: SITE + '/details/' + encodeURIComponent(d.nasa_id),
    cover: thumb ? _https(thumb.href) : undefined,
    type: 'movie',
    sourceId: SOURCE_ID,
  };
}

function _search(q, page, extra) {
  var url = API + '/search?media_type=video&page_size=30&page=' + (page || 1) +
    '&q=' + encodeURIComponent(q) + (extra || '');
  return _getJson(url).then(function (d) {
    var items = (d && d.collection && d.collection.items) || [];
    return items.map(_item).filter(function (x) { return !!x.id; });
  });
}

var YEAR = new Date().getFullYear();
var ROWS = [
  { id: 'recent', title: 'New from NASA', q: 'NASA', extra: '&year_start=' + (YEAR - 1) },
  { id: 'artemis', title: 'Artemis: back to the Moon', q: 'Artemis' },
  { id: 'apollo', title: 'Apollo missions', q: 'Apollo' },
  { id: 'mars', title: 'Mars', q: 'Mars rover' },
  { id: 'iss', title: 'International Space Station', q: 'International Space Station' },
  { id: 'webb', title: 'Hubble & Webb telescopes', q: 'telescope' },
  { id: 'earth', title: 'Our planet', q: 'Earth from space' },
];

function getHome(opts) {
  return Promise.all(ROWS.map(function (row) {
    return _search(row.q, 1, row.extra).then(
      function (items) { return { id: row.id, title: row.title, items: items }; },
      function () { return { id: row.id, title: row.title, items: [] }; }
    );
  })).then(function (rows) {
    return rows.filter(function (r) { return r.items.length > 0; });
  });
}

function getHomePage(rowId, page, opts) {
  for (var i = 0; i < ROWS.length; i++) {
    if (ROWS[i].id === rowId) return _search(ROWS[i].q, page, ROWS[i].extra);
  }
  return [];
}

function popular(opts) {
  return _search('NASA', (opts && opts.page) || 1);
}

function search(query, page, opts) {
  return _search(String(query || ''), page);
}

function _idFromUrl(url) {
  var m = String(url).match(/\/details\/([^/?#]+)/);
  return decodeURIComponent(m ? m[1] : String(url));
}

function getDetail(url) {
  var id = _idFromUrl(url);
  return _getJson(API + '/search?nasa_id=' + encodeURIComponent(id)).then(function (d) {
    var it = d && d.collection && d.collection.items && d.collection.items[0];
    if (!it) throw new Error('NASA: video not found');
    var data = it.data[0] || {};
    var base = _item(it);
    var desc = String(data.description || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    var year = String(data.date_created || '').substring(0, 4);
    return {
      id: id,
      title: base.title,
      url: SITE + '/details/' + encodeURIComponent(id),
      cover: base.cover,
      description: desc,
      status: 'completed',
      genres: (data.keywords || []).slice(0, 6),
      studios: [data.center ? 'NASA ' + data.center : 'NASA'],
      year: /^\d{4}$/.test(year) ? year : undefined,
      type: 'movie',
      sourceId: SOURCE_ID,
      episodes: [{ id: id, title: base.title, number: 1, url: id }],
    };
  });
}

function getEpisodes(seriesUrl) {
  var id = _idFromUrl(seriesUrl);
  return [{ id: id, title: 'Video', number: 1, url: id }];
}

// NASA names its renditions; heights are typical for each name.
var RENDITIONS = [
  { tag: '~orig.mp4', quality: 'Original' },
  { tag: '~large.mp4', quality: '1080p' },
  { tag: '~medium.mp4', quality: '720p' },
  { tag: '~small.mp4', quality: '480p' },
  { tag: '~mobile.mp4', quality: '360p' },
];

function getVideoSources(episodeUrl) {
  var id = _idFromUrl(episodeUrl);
  return _getJson(API + '/asset/' + encodeURIComponent(id)).then(function (d) {
    var hrefs = ((d && d.collection && d.collection.items) || []).map(function (i) { return _https(i.href); });
    var subs = hrefs.filter(function (h) { return /\.(vtt|srt)$/i.test(h); }).map(function (h) {
      return { url: h, lang: 'English', label: 'English (NASA)', format: h.split('.').pop() };
    });
    var out = [];
    RENDITIONS.forEach(function (r) {
      var h = hrefs.filter(function (x) { return x.indexOf(r.tag) > 0; })[0];
      if (h) {
        out.push({ url: encodeURI(decodeURI(h)), quality: r.quality, label: 'NASA · ' + r.quality,
                   container: 'mp4', kind: 'unknown', subtitles: subs });
      }
    });
    // Some items only have other MP4 names; offer those rather than nothing.
    if (!out.length) {
      hrefs.filter(function (h) { return /\.mp4$/i.test(h) && h.indexOf('~preview') < 0; })
        .forEach(function (h) {
          out.push({ url: encodeURI(decodeURI(h)), quality: 'Original', label: 'NASA',
                     container: 'mp4', kind: 'unknown', subtitles: subs });
        });
    }
    return out;
  });
}
