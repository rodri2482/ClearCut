// ClearCut built-in video source: Internet Archive public-domain films.
// Feature films, sci-fi/horror, noir and silent classics that the Internet
// Archive hosts as free, public-domain (or freely licensed) downloads.
// Plays the archive's own MP4 files directly, so there are no ads.

var SOURCE_ID = 'clearcut_archive';
var SITE = 'https://archive.org';
var COLLECTIONS = ['feature_films', 'SciFi_Horror', 'film_noir', 'silent_films', 'Comedy_Films'];

function getInfo() {
  return { name: 'Internet Archive (free films)', lang: 'en', baseUrl: SITE,
           logo: SITE + '/images/glogo.jpg', type: 'movie', version: '1.0.0' };
}

function _getJson(url) {
  return fetch(url, { headers: { 'Accept': 'application/json' } }).then(function (r) {
    if (!r.ok) throw new Error('Internet Archive: HTTP ' + r.status);
    try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('Internet Archive: bad JSON'); }
  });
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

function _collectionQuery(c) {
  return 'collection:(' + c + ') AND mediatype:(movies)';
}

var ROWS = [
  { id: 'popular', title: 'Most watched classics', q: _collectionQuery(COLLECTIONS.join(' OR ')), sort: 'downloads desc' },
  { id: 'scifi', title: 'Sci-fi & horror', q: _collectionQuery('SciFi_Horror'), sort: 'downloads desc' },
  { id: 'noir', title: 'Film noir', q: _collectionQuery('film_noir'), sort: 'downloads desc' },
  { id: 'comedy', title: 'Comedy', q: _collectionQuery('Comedy_Films'), sort: 'downloads desc' },
  { id: 'silent', title: 'Silent era', q: _collectionQuery('silent_films'), sort: 'downloads desc' },
  { id: 'recent', title: 'Recently added', q: _collectionQuery(COLLECTIONS.join(' OR ')), sort: 'addeddate desc' },
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
  var q = 'title:(' + String(query || '').replace(/[()":]/g, ' ') + ') AND ' +
    _collectionQuery(COLLECTIONS.join(' OR '));
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
      episodes: [{ id: id, title: _first(m.title) || 'Movie', number: 1, url: id }],
    };
  });
}

function getEpisodes(seriesUrl) {
  var id = _idFromUrl(seriesUrl);
  return [{ id: id, title: 'Movie', number: 1, url: id }];
}

function getVideoSources(episodeUrl) {
  var id = _idFromUrl(episodeUrl);
  return _getJson(SITE + '/metadata/' + id).then(function (d) {
    var files = (d && d.files) || [];
    var out = [];
    files.forEach(function (f) {
      var name = String(f.name || '');
      if (!/\.mp4$/i.test(name)) return;
      var url = SITE + '/download/' + id + '/' + encodeURIComponent(name).replace(/%2F/g, '/');
      var h = parseInt(f.height, 10);
      out.push({
        url: url,
        quality: h ? h + 'p' : (/512kb/i.test(name) ? '360p' : 'Original'),
        label: (f.format || 'MP4') + (f.size ? ' · ' + Math.round(f.size / 1048576) + ' MB' : ''),
        container: 'mp4',
        kind: 'unknown',
      });
    });
    // Biggest first: the original upload is the best quality.
    out.sort(function (a, b) { return (parseInt(b.quality, 10) || 9999) - (parseInt(a.quality, 10) || 9999); });
    return out;
  });
}
