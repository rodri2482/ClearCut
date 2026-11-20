// ClearCut built-in video source: Prelinger Archives.
// The Internet Archive's Prelinger collection — 10,000+ ephemeral, educational,
// industrial, advertising and amateur films, most of them public domain and
// free to download. Distinct from the "Internet Archive (free films)" source,
// which covers feature films, noir and silent classics.
// Plays the archive's own MP4 files directly, so there are no ads.

var SOURCE_ID = 'clearcut_prelinger';
var SITE = 'https://archive.org';
var COLLECTION = 'prelinger';

function getInfo() {
  return { name: 'Prelinger Archives (free film)', lang: 'en', baseUrl: SITE,
           logo: SITE + '/images/glogo.jpg', type: 'movie', version: '1.0.0' };
}

function _getJsonOnce(url) {
  return fetch(url, { headers: { 'Accept': 'application/json' } }).then(function (r) {
    if (!r.ok) throw new Error('Prelinger: HTTP ' + r.status);
    try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('Prelinger: bad JSON'); }
  });
}

// archive.org occasionally drops a request; one retry covers almost all of it.
function _getJson(url) {
  return _getJsonOnce(url).catch(function () { return _getJsonOnce(url); });
}

function _search(q, sort, page, rows) {
  var url = SITE + '/advancedsearch.php?q=' + encodeURIComponent(q) +
    '&fl[]=identifier&fl[]=title&fl[]=year&fl[]=description' +
    '&sort[]=' + encodeURIComponent(sort) +
    '&rows=' + (rows || 40) + '&page=' + (page || 1) + '&output=json';
  return _getJson(url).then(function (d) {
    var docs = (d && d.response && d.response.docs) || [];
    return docs.map(_item);
  });
}

function _item(doc) {
  var title = Array.isArray(doc.title) ? doc.title[0] : doc.title;
  return {
    id: doc.identifier,
    title: title || doc.identifier,
    url: SITE + '/details/' + doc.identifier,
    cover: SITE + '/services/img/' + doc.identifier,
    type: 'movie',
    sourceId: SOURCE_ID,
  };
}

// Only items with a file the player can open are listed, so tapping a title
// never ends in "couldn't load this episode".
function _query(extra) {
  return 'collection:(' + COLLECTION + ') AND mediatype:(movies) AND ' +
    'format:(MPEG4 OR "h.264" OR "512Kb MPEG4" OR "h.264 IA")' + (extra || '');
}

var PRIMARY = /\.(mp4|m4v)$/i;
var FALLBACK = /\.(mkv|webm|ogv|avi|mpe?g)$/i;

var ROWS = [
  { id: 'popular', title: 'Most watched', q: _query(), sort: 'downloads desc' },
  { id: 'guidance', title: 'Social guidance films', q: _query(' AND subject:("social guidance")'), sort: 'downloads desc' },
  { id: 'ads', title: 'Advertising & sales films', q: _query(' AND subject:(advertising)'), sort: 'downloads desc' },
  { id: 'travel', title: 'Travel & places', q: _query(' AND subject:(travel)'), sort: 'downloads desc' },
  { id: 'industry', title: 'Industry & work', q: _query(' AND subject:(industry)'), sort: 'downloads desc' },
  { id: 'recent', title: 'Recently added', q: _query(), sort: 'addeddate desc' },
];

function getHome(opts) {
  return Promise.all(ROWS.map(function (row) {
    return _search(row.q, row.sort, 1, 30).then(
      function (items) { return { id: row.id, title: row.title, items: items }; },
      function () { return { id: row.id, title: row.title, items: [] }; }
    );
  })).then(function (rows) {
    return rows.filter(function (r) { return r.items.length > 0; });
  });
}

function getHomePage(rowId, page, opts) {
  for (var i = 0; i < ROWS.length; i++) {
    if (ROWS[i].id === rowId) return _search(ROWS[i].q, ROWS[i].sort, page, 30);
  }
  return [];
}

function popular(opts) {
  var page = (opts && opts.page) || 1;
  return _search(ROWS[0].q, ROWS[0].sort, page, 40);
}

function search(query, page, opts) {
  var q = 'title:(' + String(query || '').replace(/[()":]/g, ' ') + ') AND ' + _query();
  return _search(q, 'downloads desc', page, 40);
}

function _idFromUrl(url) {
  var m = String(url).match(/\/details\/([^/?#]+)/);
  return m ? m[1] : String(url);
}

function _first(v) { return Array.isArray(v) ? v[0] : v; }

function getDetail(url) {
  var id = _idFromUrl(url);
  return _getJson(SITE + '/metadata/' + id).then(function (d) {
    var m = (d && d.metadata) || {};
    var desc = String(_first(m.description) || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    var year = String(_first(m.year) || _first(m.date) || '').substring(0, 4);
    var subjects = m.subject ? (Array.isArray(m.subject) ? m.subject : String(m.subject).split(';')) : [];
    return {
      id: id,
      title: _first(m.title) || id,
      url: SITE + '/details/' + id,
      cover: SITE + '/services/img/' + id,
      description: desc,
      status: 'completed',
      genres: subjects.map(function (s) { return String(s).trim(); }).filter(Boolean).slice(0, 6),
      studios: m.creator ? [String(_first(m.creator))] : [],
      year: /^\d{4}$/.test(year) ? year : undefined,
      type: 'movie',
      sourceId: SOURCE_ID,
      episodes: [{ id: id, title: _first(m.title) || 'Film', number: 1, url: id }],
    };
  });
}

function getEpisodes(seriesUrl) {
  var id = _idFromUrl(seriesUrl);
  return [{ id: id, title: 'Film', number: 1, url: id }];
}

function getVideoSources(episodeUrl) {
  var id = _idFromUrl(episodeUrl);
  return _getJson(SITE + '/metadata/' + id).then(function (d) {
    var files = (d && d.files) || [];
    var out = [];
    var playable = files.filter(function (f) { return PRIMARY.test(String(f.name || '')); });
    // No MP4: fall back to other formats the player (mpv) also opens.
    if (!playable.length) {
      playable = files.filter(function (f) { return FALLBACK.test(String(f.name || '')); });
    }
    playable.forEach(function (f) {
      var name = String(f.name || '');
      var url = SITE + '/download/' + id + '/' + encodeURIComponent(name).replace(/%2F/g, '/');
      var h = parseInt(f.height, 10);
      out.push({
        url: url,
        quality: h ? h + 'p' : (/512kb/i.test(name) ? '360p' : 'Original'),
        label: (f.format || 'MP4') + (f.size ? ' · ' + Math.round(f.size / 1048576) + ' MB' : ''),
        container: PRIMARY.test(name) ? 'mp4' : 'unknown',
        kind: 'unknown',
      });
    });
    // Biggest first: the original upload is the best quality.
    out.sort(function (a, b) { return (parseInt(b.quality, 10) || 9999) - (parseInt(a.quality, 10) || 9999); });
    return out;
  });
}
