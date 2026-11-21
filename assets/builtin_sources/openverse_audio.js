// ClearCut built-in source: Openverse (Creative Commons music and audio).
// Openverse is the WordPress Foundation's search index of CC-licensed media.
// It has a public API with no key; every result carries its creator and the
// exact licence, which we show in the Sources sheet. The audio URL is the
// provider's own file, so there are no ads and no embed page to scrape.

var SOURCE_ID = 'clearcut_openverse';
var API = 'https://api.openverse.org/v1/audio/';

function getInfo() {
  return {
    name: 'Openverse (free music)',
    lang: 'en',
    baseUrl: 'https://openverse.org',
    logo: 'https://openverse.org/favicon.ico',
    type: 'movie',
    version: '1.0.0',
  };
}

function _getJson(url) {
  // Openverse rejects requests without a descriptive User-Agent on some
  // networks (the Android fetch channel sends a bare default otherwise).
  return fetch(url, {
    headers: {
      Accept: 'application/json',
      'User-Agent': 'ClearCut/1.0 (legal built-in source)',
    },
  }).then(function (r) {
    if (!r.ok) throw new Error('Openverse: HTTP ' + r.status);
    try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('Openverse: bad JSON'); }
  });
}

function _idFromUrl(url) {
  var m = String(url || '').match(/\/([0-9a-f-]{36})\/?$/);
  return m ? m[1] : String(url);
}

function _item(r) {
  return {
    id: r.id,
    title: r.title || r.id,
    url: API + r.id + '/',
    cover: r.thumbnail || undefined,
    type: 'movie',
    sourceId: SOURCE_ID,
  };
}

function _query(term, page) {
  var parts = [
    'q=' + encodeURIComponent(term || 'music'),
    'page=' + (page || 1),
    'page_size=30',
  ];
  return _getJson(API + '?' + parts.join('&')).then(function (d) {
    return (d && d.results) || [];
  }, function () { return []; });
}

function getHome(opts) {
  var shelves = [
    { id: 'ambient', title: 'Ambient', term: 'ambient' },
    { id: 'classical', title: 'Classical', term: 'classical' },
    { id: 'jazz', title: 'Jazz', term: 'jazz' },
  ];
  return Promise.all(shelves.map(function (s) {
    return _query(s.term, 1).then(function (rows) {
      return { id: s.id, title: s.title, items: rows.map(_item) };
    });
  })).then(function (rows) {
    return rows.filter(function (r) { return r.items.length > 0; });
  });
}

function getHomePage(rowId, page, opts) {
  var terms = { ambient: 'ambient', classical: 'classical', jazz: 'jazz' };
  var term = terms[rowId];
  if (!term) return [];
  return _query(term, page).then(function (rows) { return rows.map(_item); });
}

function popular(opts) {
  return _query('music', (opts && opts.page) || 1).then(function (rows) {
    return rows.map(_item);
  });
}

function search(query, page, opts) {
  return _query(query || 'music', page).then(function (rows) {
    return rows.map(_item);
  });
}

function getDetail(url) {
  var id = _idFromUrl(url);
  return _getJson(API + encodeURIComponent(id) + '/').then(function (r) {
    if (!r || !r.url) throw new Error('Openverse: track not found');
    return {
      id: r.id,
      title: r.title || r.id,
      url: url,
      cover: r.thumbnail || undefined,
      description: String(r.attribution || '').replace(/<[^>]+>/g, ' ').trim(),
      status: 'completed',
      genres: r.genres || [],
      studios: r.creator ? [r.creator] : [],
      type: 'movie',
      sourceId: SOURCE_ID,
      episodes: [{ id: r.id, title: r.title || 'Track', number: 1, url: url }],
    };
  });
}

function getEpisodes(seriesUrl) {
  return [{ id: String(seriesUrl), title: 'Track', number: 1, url: seriesUrl }];
}

function getVideoSources(episodeUrl, fast) {
  var id = _idFromUrl(episodeUrl);
  return _getJson(API + encodeURIComponent(id) + '/').then(function (r) {
    if (!r || !r.url) return [];
    var label = (r.creator ? r.creator + ' · ' : '') + (r.license || 'CC');
    return [{
      url: r.url,
      quality: 'Audio',
      label: label,
      container: 'unknown',
      kind: 'unknown',
    }];
  });
}
