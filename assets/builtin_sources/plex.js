// ClearCut built-in source: Plex Watch (watch.plex.tv) — Plex's own free,
// ad-supported movie/TV/anime catalog. Everything here uses the public calls
// the site's own web client makes. It creates an anonymous Plex account via
// Plex's public endpoint (no email, no sign-in, no Plex Pass) and uses that
// token for free AVOD items only. No DRM, paid content, geoblock evasion or
// ad-skip/VMAP manipulation is touched; the service's ad pods stay intact.

var SITE = 'https://watch.plex.tv';
var LUMA = 'https://luma.plex.tv/api';
var VOD = 'https://vod.provider.plex.tv';
var SOURCE_ID = 'clearcut_plex';
var CLIENT_ID = 'clearcut-' + Date.now() + '-' + Math.floor(Math.random() * 1000000000);
var HEADERS = {
  'X-Plex-Client-Identifier': CLIENT_ID,
  'X-Plex-Product': 'Plex Mediaverse',
  'X-Plex-Version': '7.6.0',
  'X-Plex-Provider-Version': '7.6.0',
  'X-Plex-Luma-Version': '1',
  'X-Plex-Luma-Layout': 'tv',
  Accept: 'application/json'
};
var tokenPromise = null;

function getInfo() {
  return {
    name: 'Plex Watch', lang: 'en', baseUrl: SITE,
    type: 'movie', version: '1.0.0'
  };
}

function ensureToken() {
  if (tokenPromise) return tokenPromise;
  var body = JSON.stringify({});
  tokenPromise = fetch('https://plex.tv/api/v2/users/anonymous', {
    method: 'POST',
    headers: HEADERS,
    body: body,
    timeoutMs: 9000
  }).then(function (response) {
    if (!response.ok) throw new Error('Plex: anonymous account HTTP ' + response.status);
    var data = JSON.parse(response.body);
    if (!data.authToken) throw new Error('Plex: no anonymous token');
    return data.authToken;
  }).catch(function (e) {
    tokenPromise = null; // let the next call retry
    throw e;
  });
  return tokenPromise;
}

function getJson(path, timeoutMs) {
  return ensureToken().then(function (token) {
    var headers = {};
    for (var k in HEADERS) headers[k] = HEADERS[k];
    headers['X-Plex-Token'] = token;
    return fetch(path, {headers: headers, timeoutMs: timeoutMs || 9000});
  }).then(function (response) {
    if (!response.ok) throw new Error('Plex: HTTP ' + response.status);
    return JSON.parse(response.body);
  });
}

function hashOf(value) {
  var m = /([a-f0-9]{24})/i.exec(String(value || ''));
  return m ? m[1] : undefined;
}

function imageUrl(source) {
  var url = typeof source === 'string' ? source : (source && (source.url || source.optimizerUrl));
  return /^https:\/\//.test(String(url || '')) ? String(url) : undefined;
}

function titleType(url) {
  return /\/show\//.test(String(url || '')) ? 'tv' : 'movie';
}

// Tiles from the on-demand rails carry the id in `metricsID` even when
// `data.metadata` is absent (the search results do have data.metadata).
function railItem(tile) {
  var hash = hashOf(tile.metricsID || tile.id || (tile.link && tile.link.url));
  if (!hash || !tile.title) return null;
  var type = titleType(tile.link && tile.link.url);
  var subtitles = Array.isArray(tile.subtitles) ? tile.subtitles : [];
  var year = /(\d{4})/.exec(subtitles.join(' '));
  var slugMatch = /\/show\/([^?]+)/.exec(String((tile.link && tile.link.url) || ''));
  return {
    id: type + ':' + hash,
    title: String(tile.title),
    // Rail tiles carry the free VOD hash directly — no lookup needed.
    url: 'plex://' + type + '/' + hash + (type === 'tv' && slugMatch ? '/' + slugMatch[1] : ''),
    type: type,
    cover: imageUrl(tile.image),
    year: year ? year[1] : undefined,
    sourceId: SOURCE_ID
  };
}

function searchItem(result) {
  var meta = result && result.data && result.data.metadata;
  if (!meta) return null;
  var hash = hashOf(meta.guid || meta.key);
  if (!hash || !meta.title) return null;
  var type = meta.type === 'show' ? 'tv' : (meta.type === 'movie' ? 'movie' : null);
  if (!type) return null;
  var slugMatch = /\/show\/([^?]+)/.exec(String((result.link && result.link.url) || ''));
  return {
    id: type + ':' + hash,
    title: String(meta.title),
    // Discover search gives a catalog hash, not the free-VOD hash. Keep the
    // slug so getDetail can resolve it through Plex's public action endpoint.
    url: 'plex://' + type + '/' + hash + (type === 'tv' && slugMatch ? '/' + slugMatch[1] : ''),
    type: type,
    cover: imageUrl(result.artwork && result.artwork.image),
    year: meta.year ? String(meta.year) : undefined,
    sourceId: SOURCE_ID
  };
}

function items(list, mapper) {
  return (Array.isArray(list) ? list : []).map(mapper).filter(Boolean);
}

var SHELVES = [
  ['anime', 'Anime (free on Plex)'],
  ['trending', 'Most popular'],
  ['action', 'Action'],
  ['comedy', 'Comedy'],
  ['documentary', 'Documentaries']
];

function getHome(opts) {
  return Promise.all(SHELVES.map(function (shelf) {
    return getJson(LUMA + '/screen/on-demand/list/' + shelf[0], 12000)
      .then(function (data) {
        return {
          id: shelf[0], title: shelf[1],
          items: items(data && data.ui && data.ui.list && data.ui.list.content, railItem)
        };
      }).catch(function () {
        return {id: shelf[0], title: shelf[1], items: []};
      });
  })).then(function (rows) {
    return rows.filter(function (row) { return row.items.length > 0; });
  });
}

function getHomePage(rowId, page, opts) {
  if (page > 1 || !SHELVES.some(function (s) { return s[0] === rowId; })) return [];
  return getJson(LUMA + '/screen/on-demand/list/' + rowId, 12000).then(function (data) {
    return items(data && data.ui && data.ui.list && data.ui.list.content, railItem);
  });
}

function popular(opts) {
  return getJson(LUMA + '/screen/on-demand/list/trending', 12000).then(function (data) {
    return items(data && data.ui && data.ui.list && data.ui.list.content, railItem);
  });
}

function search(query, page, opts) {
  var term = String(query || '').trim();
  if (!term) return popular(opts);
  return getJson(LUMA + '/screen/search?query=' + encodeURIComponent(term), 12000)
    .then(function (data) {
      return items(data && data.ui && data.ui.results, searchItem);
    });
}

function parseRef(url) {
  var parts = String(url || '').replace(/^plex:\/\//, '').split('/');
  var type = parts[0];
  var hash = parts[1];
  if ((type !== 'movie' && type !== 'tv') || !/^[a-f0-9]{24}$/i.test(hash || '')) {
    throw new Error('Plex: invalid title or episode reference');
  }
  var rest = parts.slice(2);
  var season, episode, episodeHash, slug;
  if (rest.length === 1 && !/^\d+$/.test(rest[0])) {
    slug = rest[0]; // search result: needs discover -> vod resolution
  } else if (rest.length >= 2 && /^\d+$/.test(rest[0]) && /^\d+$/.test(rest[1])) {
    season = rest[0];
    episode = rest[1];
    episodeHash = rest[2];
  }
  return {type: type, hash: hash, season: season, episode: episode,
    episodeHash: episodeHash, slug: slug};
}

// Search lives in the discover catalog; free episodes live in the VOD
// catalog. Plex's own public action endpoint returns the VOD URI for a slug.
function resolveVod(ref) {
  if (ref.type === 'movie' || !ref.slug) return Promise.resolve(ref.hash);
  return getJson(
    LUMA + '/api/action/get-actions-for-metadata-item?slug=show%3A' +
    encodeURIComponent(ref.slug), 9000
  ).then(function (data) {
    var actions = (data && data.actions) || [];
    for (var i = 0; i < actions.length; i++) {
      var link = actions[i].link && actions[i].link.url;
      var hash = hashOf(decodeURIComponent(String(link || '')));
      if (hash) return hash;
    }
    return ref.hash;
  }).catch(function () { return ref.hash; });
}

function metadata(hash) {
  return getJson(VOD + '/library/metadata/' + hash, 9000).then(function (data) {
    var m = data && data.MediaContainer && data.MediaContainer.Metadata;
    var item = Array.isArray(m) ? m[0] : m;
    if (!item) throw new Error('Plex: title unavailable');
    return item;
  });
}

function episodeList(hash) {
  return getJson(VOD + '/library/metadata/' + hash + '/children', 9000).then(function (data) {
    var c = data && data.MediaContainer && data.MediaContainer.Metadata;
    var seasons = Array.isArray(c) ? c : (c ? [c] : []);
    return Promise.all(seasons.map(function (season) {
      var seasonNum = Number(season.index) || 1;
      return getJson(VOD + '/library/metadata/' + season.ratingKey + '/children', 9000)
        .then(function (children) {
          var eps = children && children.MediaContainer && children.MediaContainer.Metadata;
          return (Array.isArray(eps) ? eps : (eps ? [eps] : [])).map(function (ep) {
            return {
              id: 's' + seasonNum + 'e' + (Number(ep.index) || 0),
              title: 'S' + seasonNum + ' E' + (Number(ep.index) || 0) +
                (ep.title ? ' · ' + ep.title : ''),
              number: Number(ep.index) || 0,
              url: 'plex://tv/' + hash + '/' + seasonNum + '/' + (Number(ep.index) || 0) +
                '/' + ep.ratingKey,
              date: ep.originallyAvailableAt || ''
            };
          });
        }).catch(function () { return []; });
    })).then(function (groups) {
      return [].concat.apply([], groups).filter(function (ep) { return ep.number > 0; });
    });
  });
}

function getDetail(url, opts) {
  var ref = parseRef(url);
  return resolveVod(ref).then(function (vodHash) {
    return metadata(vodHash).then(function (m) {
      var detail = {
        id: ref.hash,
        title: String(m.title || ''),
        url: url,
        type: ref.type,
        cover: imageUrl(m.thumb),
        banner: imageUrl(m.art),
        description: String(m.summary || ''),
        genres: (Array.isArray(m.Genre) ? m.Genre : []).map(function (g) { return g.tag; }).filter(Boolean),
        year: m.year ? String(m.year) : undefined,
        status: ref.type === 'movie' ? 'Released' : 'Ongoing',
        sourceId: SOURCE_ID
      };
      if (ref.type === 'movie') {
        detail.episodes = [{
          id: 'movie', title: String(m.title || 'Movie'), number: 1, url: url
        }];
        return detail;
      }
      return episodeList(vodHash).then(function (episodes) {
        detail.episodes = episodes;
        return detail;
      });
    });
  });
}

function getEpisodes(url, opts) {
  var ref = parseRef(url);
  if (ref.type === 'movie') {
    return Promise.resolve([{id: 'movie', title: 'Movie', number: 1, url: url}]);
  }
  return resolveVod(ref).then(function (vodHash) {
    return episodeList(vodHash);
  });
}

function streamSources(item, url) {
  var out = [];
  var media = Array.isArray(item.Media) ? item.Media : (item.Media ? [item.Media] : []);
  for (var i = 0; i < media.length; i++) {
    var m = media[i];
    if (!m || m.drm === true || m.drm === 'true') continue;
    var parts = Array.isArray(m.Part) ? m.Part : (m.Part ? [m.Part] : []);
    for (var j = 0; j < parts.length; j++) {
      var key = parts[j] && parts[j].key;
      if (!key) continue;
      var quality = Number(m.height) > 0 ? String(m.height) + 'p' : (m.protocol || 'Auto');
      out.push({
        url: VOD + key,
        container: m.protocol === 'dash' ? 'dash' : 'hls',
        quality: quality,
        label: 'Plex ' + quality,
        headers: {},
        sourceId: SOURCE_ID,
        episodeUrl: url
      });
    }
  }
  return out;
}

function getVideoSources(episodeUrl, fast) {
  var ref = parseRef(episodeUrl);
  return ensureToken().then(function (token) {
    var hash = ref.episodeHash || ref.hash;
    return metadata(hash).then(function (m) {
      var sources = streamSources(m, episodeUrl);
      for (var i = 0; i < sources.length; i++) {
        // A token is mandatory for the manifest. Query form lets the native
        // player and ClearCut's verifier both fetch it without extra headers.
        sources[i].url += (sources[i].url.indexOf('?') >= 0 ? '&' : '?') +
          'X-Plex-Token=' + encodeURIComponent(token);
      }
      return sources;
    });
  });
}
