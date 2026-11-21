// ClearCut built-in video source: PeerTube (public, federated video).
// Reads each instance's public REST API — no account, no key. The streams we
// hand to the player are the instance's own HLS master and MP4 files, with the
// instance named in every quality label so the Sources sheet reads like a list
// of servers.

var SOURCE_ID = 'clearcut_peertube';
var INSTANCES = ['https://peertube.tv', 'https://framatube.org'];

function getInfo() {
  return {
    name: 'PeerTube (free public video)',
    lang: 'en',
    baseUrl: INSTANCES[0],
    logo: INSTANCES[0] + '/favicon.ico',
    type: 'movie',
    version: '1.0.0',
  };
}

function _getJson(url) {
  return fetch(url, { headers: { Accept: 'application/json' } }).then(function (r) {
    if (!r.ok) throw new Error('PeerTube: HTTP ' + r.status);
    try { return JSON.parse(r.body || 'null'); } catch (e) { throw new Error('PeerTube: bad JSON'); }
  });
}

// One instance failing must not hide the others.
function _list(instance, count, page) {
  var start = Math.max(0, ((page || 1) - 1) * (count || 30));
  var url = instance + '/api/v1/videos?count=' + (count || 30) + '&start=' + start;
  return _getJson(url).then(
    function (d) { return (d && d.data) || []; },
    function () { return []; }
  );
}

function _host(instance) { return String(instance).replace(/^https?:\/\//, ''); }

// The uuid AND the instance are encoded in the url: a federated video's id is
// only unique on the instance that serves it.
function _url(v, instance) {
  return 'peertube://' + v.uuid + '@' + _host(instance);
}

function _parseUrl(url) {
  var m = String(url || '').match(/^peertube:\/\/([^@]+)@(.+)$/);
  if (!m) return null;
  return { uuid: m[1], instance: 'https://' + m[2], host: m[2] };
}

function _item(v, instance) {
  return {
    id: v.uuid,
    title: v.name || v.uuid,
    url: _url(v, instance),
    cover: v.thumbnailPath
      ? (v.thumbnails && v.thumbnails.length
          ? (v.thumbnails[v.thumbnails.length - 1].fileUrl || instance + v.thumbnailPath)
          : instance + v.thumbnailPath)
      : undefined,
    type: 'movie',
    sourceId: SOURCE_ID,
  };
}

function _rows(ids, titles, count, page) {
  return Promise.all(INSTANCES.map(function (instance, i) {
    return _list(instance, count, page).then(function (data) {
      return {
        id: ids[i],
        title: titles[i] + ' · ' + _host(instance),
        items: data.map(function (v) { return _item(v, instance); }),
      };
    });
  })).then(function (rows) {
    return rows.filter(function (r) { return r.items.length > 0; });
  });
}

function getHome(opts) {
  return _rows(
    ['latest-0', 'latest-1'],
    ['Latest videos', 'Latest videos'],
    24,
    1
  );
}

function getHomePage(rowId, page, opts) {
  var m = String(rowId || '').match(/^latest-(\d+)$/);
  if (!m) return [];
  var i = parseInt(m[1], 10);
  if (i < 0 || i >= INSTANCES.length) return [];
  return _list(INSTANCES[i], 30, page).then(function (data) {
    return data.map(function (v) { return _item(v, INSTANCES[i]); });
  });
}

function popular(opts) {
  var page = (opts && opts.page) || 1;
  return Promise.all(INSTANCES.map(function (instance) {
    return _list(instance, 40, page).then(function (data) {
      return data.map(function (v) { return _item(v, instance); });
    });
  })).then(function (all) {
    return [].concat.apply([], all);
  });
}

function search(query, page, opts) {
  var q = String(query || '').toLowerCase().trim();
  if (!q) return popular(opts);
  return Promise.all(INSTANCES.map(function (instance) {
    return _list(instance, 60, 1).then(function (data) {
      return data.filter(function (v) {
        return String(v.name || '').toLowerCase().indexOf(q) >= 0 ||
          String((v.channel && v.channel.displayName) || '').toLowerCase().indexOf(q) >= 0;
      }).map(function (v) { return _item(v, instance); });
    });
  })).then(function (all) {
    return [].concat.apply([], all);
  });
}

function _detail(url) {
  var ref = _parseUrl(url);
  if (!ref) throw new Error('PeerTube: bad video url');
  return _getJson(ref.instance + '/api/v1/videos/' + encodeURIComponent(ref.uuid))
    .then(function (d) {
      if (!d || !d.uuid) throw new Error('PeerTube: video not found');
      return { d: d, ref: ref };
    });
}

function _strip(html) {
  return String(html || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function getDetail(url) {
  return _detail(url).then(function (res) {
    var d = res.d, ref = res.ref;
    return {
      id: d.uuid,
      title: d.name,
      url: url,
      cover: d.thumbnailPath ? ref.instance + d.thumbnailPath : undefined,
      description: _strip(d.description).substring(0, 900),
      status: 'completed',
      genres: (d.tags || []).slice(0, 6),
      studios: d.channel ? [d.channel.displayName || d.channel.name] : [],
      year: d.publishedAt ? String(d.publishedAt).substring(0, 4) : undefined,
      type: 'movie',
      sourceId: SOURCE_ID,
      episodes: [
        { id: d.uuid, title: d.name, number: 1, url: url },
      ],
    };
  });
}

function getEpisodes(seriesUrl) {
  return [
    { id: String(seriesUrl), title: 'Video', number: 1, url: seriesUrl },
  ];
}

function _mb(size) {
  return size ? ' · ' + Math.round(size / 1048576) + ' MB' : '';
}

function getVideoSources(episodeUrl, fast) {
  return _detail(episodeUrl).then(function (res) {
    var d = res.d, ref = res.ref;
    var out = [];

    // The HLS master is the adaptive rendition — quality switching stays on
    // one server instead of reopening a different file.
    var playlists = d.streamingPlaylists || [];
    if (playlists.length && playlists[0].playlistUrl) {
      out.push({
        url: playlists[0].playlistUrl,
        quality: 'Auto',
        label: ref.host + ' · HLS',
        container: 'hls',
        kind: 'unknown',
      });
    }

    var files = (d.files || []).filter(function (f) {
      return f.fileUrl && f.hasVideo !== false;
    });
    files.forEach(function (f) {
      var label = (f.resolution && f.resolution.label) || 'Original';
      out.push({
        url: f.fileUrl,
        quality: label,
        label: ref.host + ' · ' + label + _mb(f.size),
        container: 'mp4',
        kind: 'unknown',
      });
    });
    // Highest resolution first, Auto adaptive last.
    out.sort(function (a, b) {
      if (a.quality === 'Auto') return 1;
      if (b.quality === 'Auto') return -1;
      return (parseInt(b.quality, 10) || 0) - (parseInt(a.quality, 10) || 0);
    });
    return out;
  });
}
