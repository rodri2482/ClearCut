// FrameXTV's JSON endpoints feed ClearCut's existing catalogue and video player.
var API = 'https://api.framextv.tech';
var SITE = 'https://framextv.cc';
var SOURCE_ID = 'clearcut_framextv';
var ROWS = [
  ['trending_movies', 'Trending movies', '/api/trending', {type: 'movie'}],
  ['popular_movies', 'Popular movies'],
  ['popular_tv', 'Popular TV'],
  ['popular_anime', 'Popular anime', '/anime/api/popular', {}],
  ['new_releases', 'New releases'],
  ['action_movies', 'Action', '/api/discover', {type: 'movie', genre: 28}],
  ['scifi_movies', 'Science fiction', '/api/discover', {type: 'movie', genre: 878}],
  ['thriller_movies', 'Thrillers', '/api/discover', {type: 'movie', genre: 53}],
  ['comedy_movies', 'Comedy', '/api/discover', {type: 'movie', genre: 35}],
  ['airing_anime', 'Airing anime'],
];

function getInfo() {
  return {name: 'FrameXTV', lang: 'en', baseUrl: SITE, type: 'movie', version: '1.0.0'};
}

function json(path, params) {
  var query = Object.keys(params || {}).map(function (key) {
    return encodeURIComponent(key) + '=' + encodeURIComponent(params[key]);
  }).join('&');
  return fetch(API + path + (query ? '?' + query : ''), {
    headers: {Accept: 'application/json'},
  }).then(function (response) {
    if (!response.ok) throw new Error('FrameXTV: HTTP ' + response.status);
    var data = JSON.parse(response.body);
    if (!data || data.success === false) throw new Error('FrameXTV: unavailable');
    return data;
  });
}

function list(value) { return Array.isArray(value) ? value : []; }
function positive(value) { return /^[1-9][0-9]*$/.test(String(value)); }
function text(value) { return typeof value === 'string' ? value.trim() : ''; }
function mediaUrl(value) {
  var url = text(value);
  // The anime endpoint sometimes returns its own API-relative media URLs.
  if (/^\/(?:anime\/)?api\//.test(url)) url = API + url;
  return /^https:\/\/[^\s/?#@\\]+(?:[/?#]|$)/i.test(url) ? url : undefined;
}

function showUrl(type, id) { return 'framextv://' + type + '/' + id; }

function parseRef(url) {
  var match = /^framextv:\/\/(movie|tv|anime)\/([1-9]\d*)(?:\/(0|[1-9]\d*)\/([1-9]\d*))?$/.exec(String(url));
  if (!match) throw new Error('FrameXTV: invalid title or episode');
  return {type: match[1], id: match[2], season: match[3], episode: match[4]};
}

function mapItem(record, typeHint) {
  var rawType = typeHint || record.type;
  var type = rawType === 'series' ? 'tv' : rawType;
  var id = type === 'anime' ? (record.anilistId || record.id) : record.id;
  var title = text(record.title) || text(record.name);
  if (['movie', 'tv', 'anime'].indexOf(type) < 0 || !positive(id) || !title) return null;
  return {
    id: type + ':' + id,
    title: title,
    url: showUrl(type, id),
    type: type === 'anime' ? 'anime' : 'movie',
    cover: mediaUrl(record.poster || record.image),
    banner: mediaUrl(record.backdrop),
    year: record.year ? String(record.year) : undefined,
    anilistId: type === 'anime' ? Number(id) : undefined,
    tmdbId: type === 'anime' ? undefined : Number(id),
    tmdbIsTv: type === 'tv',
    sourceId: SOURCE_ID,
  };
}

function items(records, hint) {
  return list(records).filter(Boolean).map(function (record) {
    return mapItem(record, hint);
  }).filter(Boolean);
}

function getHome() {
  return Promise.all([
    json('/api/home', {}),
    json('/api/reels', {page: 1}).catch(function () { return {}; }),
  ]).then(function (responses) {
    var rails = responses[0].rails || {};
    var rows = ROWS.map(function (row) {
      return {id: row[2] ? row[0] : null, title: row[1], items: items((rails[row[0]] || {}).results)};
    });
    rows.push({id: 'reels', title: 'From FrameXTV Reels', items: items(responses[1].results)});
    return rows.filter(function (row) { return row.items.length > 0; });
  });
}

function getHomePage(rowId, page) {
  if (rowId === 'reels') {
    return json('/api/reels', {page: page}).then(function (data) { return items(data.results); });
  }
  var row = ROWS.find(function (entry) { return entry[0] === rowId; });
  if (!row || !row[2]) return [];
  return json(row[2], {...row[3], page: page}).then(function (data) {
    return items(data.results, rowId === 'popular_anime' ? 'anime' : undefined);
  });
}

function popular(options) {
  return getHomePage('trending_movies', (options && options.page) || 1);
}

function search(query, page, options) {
  var term = text(query);
  if (!term) return popular({page: page});
  var params = {q: term, page: page || 1};
  return Promise.all([
    json('/api/search', params).then(function (data) { return items(data.results); }).catch(function () { return []; }),
    json('/anime/api/search', params).then(function (data) { return items(data.results, 'anime'); }).catch(function () { return []; }),
  ]).then(function (results) {
    var seen = new Set();
    return results[0].concat(results[1]).filter(function (item) {
      if (seen.has(item.url)) return false;
      seen.add(item.url);
      return true;
    });
  });
}

function rawDetail(ref) {
  return json(ref.type === 'anime' ? '/anime/api/details' : '/api/details',
    ref.type === 'anime' ? {id: ref.id} : {id: ref.id, type: ref.type});
}

function videoEpisodes(ref, data) {
  var base = showUrl(ref.type, ref.id);
  if (ref.type === 'movie' || (ref.type === 'anime' && text(data.format).toLowerCase() === 'movie')) {
    return Promise.resolve([{id: 'movie', title: text(data.title) || 'Movie', number: 1, url: base}]);
  }
  if (ref.type === 'anime') {
    // AniList IDs describe a particular entry, rather than every season of a franchise.
    var count = [data.numberOfEpisodes, data.episodes]
      .map(Number).find(function (n) { return Number.isInteger(n) && n > 0; }) || 0;
    var season = list(data.seasons).find(function (s) {
      return s.id != null && String(s.id) === ref.id && positive(s.number);
    });
    var seasonNum = season ? Number(season.number) : 1;
    return Promise.resolve(Array.from({length: Math.min(count, 2000)}, function (_, index) {
      var n = index + 1;
      return {id: String(n), title: 'Episode ' + n, number: n, url: base + '/' + seasonNum + '/' + n};
    }));
  }

  // The season summaries already include episode counts. Only fetch full
  // season details when there's a single season. Multi-season shows can still
  // play directly from their exact TMDB season and episode identifiers.
  var seasons = list(data.seasons).filter(function (season) {
    return positive(season.season_number) && Number(season.episode_count) > 0;
  }).sort(function (a, b) { return a.season_number - b.season_number; });
  function episodesFor(season, data) {
    var seasonNum = Number(season.season_number);
    var episodes = list(data && data.episodes);
    if (!episodes.length) {
      episodes = Array.from({length: Math.min(Number(season.episode_count), 2500)}, function (_, index) {
        return {episode_number: index + 1};
      });
    }
    return episodes.filter(function (episode) { return positive(episode.episode_number); })
      .map(function (episode) {
        var n = Number(episode.episode_number);
        return {
          id: seasonNum + ':' + n,
          title: 'S' + seasonNum + ' E' + n + (episode.name ? ' · ' + episode.name : ''),
          number: n,
          url: base + '/' + seasonNum + '/' + n,
          date: episode.air_date,
          thumbnail: mediaUrl(episode.still),
        };
      });
  }
  if (seasons.length === 1) {
    var season = seasons[0];
    return json('/api/season', {id: ref.id, season: season.season_number})
      .catch(function () { return null; })
      .then(function (seasonDetail) { return episodesFor(season, seasonDetail); });
  }
  return Promise.resolve([].concat.apply([], seasons.map(function (season) {
    return episodesFor(season);
  })));
}

function getDetail(url) {
  var ref = parseRef(url);
  return rawDetail(ref).then(function (data) {
    var item = mapItem({...data, id: ref.id}, ref.type);
    if (!item) throw new Error('FrameXTV: title unavailable');
    return videoEpisodes(ref, data).then(function (episodes) {
      var rating = Number(data.rating);
      return {
        ...item,
        description: text(data.overview) || text(data.synopsis),
        genres: list(data.genres).filter(function (genre) { return typeof genre === 'string'; }),
        cast: list(data.cast).map(function (member) { return text(member.name); }).filter(Boolean),
        format: ref.type === 'movie' ? 'Movie' : text(data.format) || 'TV',
        durationMins: positive(data.runtime) ? Number(data.runtime) : undefined,
        score: rating > 0 && rating <= 10 ? Math.round(rating * 10) : undefined,
        episodes: episodes,
      };
    });
  });
}

function getEpisodes(url) {
  return getDetail(url).then(function (detail) { return detail.episodes; });
}

function requestHeaders(globalHeaders, sourceHeaders) {
  var allowed = {'referer': 'Referer', 'origin': 'Origin', 'user-agent': 'User-Agent'};
  var headers = {};
  [globalHeaders, sourceHeaders].filter(Boolean).forEach(function (input) {
    Object.keys(input).forEach(function (name) {
      var key = allowed[name.toLowerCase()];
      var value = text(input[name]);
      if (key && value && !/[\r\n]/.test(value)) headers[key] = value;
    });
  });
  return headers;
}

function subtitleTracks(raw) {
  var seen = new Set();
  return raw.map(function (track) {
    if (!track) return null;
    var url = mediaUrl(track.url || track.file);
    if (!url || seen.has(url)) return null;
    seen.add(url);
    return {
      url: url,
      lang: text(track.lang) || text(track.language) || text(track.label) || 'und',
      label: text(track.label) || undefined,
      format: text(track.format) || undefined,
      default: track.isDefault === true || track.default === true,
    };
  }).filter(Boolean);
}

function getVideoSources(url) {
  var ref = parseRef(url);
  if (ref.type === 'tv' && !ref.episode) return [];
  var anime = ref.type === 'anime';
  var params = {id: ref.id, type: anime && !ref.episode ? 'movie' : ref.type};
  if (ref.episode) {
    params.season = ref.season;
    params.episode = ref.episode;
  }
  if (anime) params.sub_type = 'sub';

  return json(anime ? '/anime/api/stream' : '/api/stream', params).then(function (data) {
    var seen = new Set();
    return list(data.sources).map(function (source) {
      if (!source) return null;
      var link = mediaUrl(source.url);
      var type = text(source.type).toLowerCase();
      if (!link || (type !== 'hls' && type !== 'mp4') || seen.has(link)) return null;
      seen.add(link);
      var audio = text(source.audio || data.audio).toLowerCase();
      return {
        url: link,
        container: type,
        label: text(source.server || data.server) || 'FrameXTV',
        quality: text(source.quality) || undefined,
        kind: audio === 'dub' || audio === 'sub' ? audio : 'unknown',
        headers: requestHeaders(data.headers, source.headers),
        subtitles: subtitleTracks(list(source.subtitles).concat(list(data.subtitles))),
      };
    }).filter(Boolean);
  });
}
