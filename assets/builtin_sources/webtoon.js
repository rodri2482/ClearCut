// ClearCut built-in MANGA source: WEBTOON (www.webtoons.com).
// Free, official, ad-supported webcomics from Naver's own site. The site's
// own ads are left intact; nothing here strips or bypasses them.
//
// CloudStream-shaped JS provider, same contract as framextv.js: the bootstrap
// wraps these globals into __providers['clearcut_webtoon']. `getPages` returns
// comic panel images for the reader. Every value below comes from HTML the
// site itself serves to a plain browser — no private API, no token, no login.
//
// Verified live 2026-11-26 from this machine and from a phone: catalog,
// search, series and reader pages all return 200 with the markup parsed here.

var SITE = 'https://www.webtoons.com';
var SOURCE_ID = 'clearcut_webtoon';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36';
var MAX_EPISODE_PAGES = 5; // ~45 newest chapters; a full 300-chapter walk is too slow for one JS call.

function getInfo() {
  return {
    name: 'WEBTOON',
    lang: 'en',
    baseUrl: SITE,
    type: 'manga',
    version: '1.0.0'
  };
}

function html(path, timeoutMs) {
  return fetch(SITE + path, {
    headers: {'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9'},
    timeoutMs: timeoutMs || 9000
  }).then(function (response) {
    if (!response.ok) throw new Error('WEBTOON: HTTP ' + response.status);
    return response.body;
  });
}

function decode(value) {
  return String(value == null ? '' : value)
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, function (_, d) { return String.fromCharCode(Number(d)); })
    .replace(/&amp;/g, '&')
    .trim();
}

function pick(pattern, text, group) {
  var m = pattern.exec(text);
  return m ? decode(m[group || 1]) : undefined;
}

// Every series card on a genre or search page is an anchor carrying title_no.
// The same shape is used on /en/{genre}, /en/search and /en/genres.
function parseCards(page) {
  var out = [];
  var re = /<a\b[^>]*href="(https:\/\/www\.webtoons\.com\/en\/[a-z-]+\/[a-z0-9-]+\/list\?title_no=(\d+))"[^>]*>([\s\S]*?)<\/a>/g;
  var m;
  while ((m = re.exec(page)) !== null) {
    var card = m[3];
    var title = pick(/<strong class="title">([^<]*)<\/strong>/, card);
    if (!title) continue;
    out.push({
      id: 'title_no:' + m[2],
      title: title,
      url: decode(m[1]),
      type: 'manga',
      cover: pick(/<img\b[^>]+(?:data-src|src)="([^"]+)"/, card),
      author: pick(/<div class="author">([^<]*)<\/div>/, card),
      genres: [],
      sourceId: SOURCE_ID
    });
  }
  return out;
}

function unique(items) {
  var seen = {};
  return items.filter(function (item) {
    if (!item || !item.url || seen[item.url]) return false;
    seen[item.url] = true;
    return true;
  });
}

var SHELVES = [
  ['romance', 'Romance'],
  ['fantasy', 'Fantasy'],
  ['action', 'Action'],
  ['comedy', 'Comedy'],
  ['drama', 'Drama']
];

function getHome(opts) {
  return Promise.all(SHELVES.map(function (shelf) {
    return html('/en/' + shelf[0], 9000).then(function (page) {
      return {id: shelf[0], title: shelf[1], items: parseCards(page)};
    }).catch(function () { return {id: shelf[0], title: shelf[1], items: []}; });
  })).then(function (rows) {
    return rows.filter(function (row) { return row.items.length > 0; });
  });
}

// WEBTOON ignores a `page` parameter on its genre shelf (it returns the same
// shelf again), so paging beyond the first page would serve duplicates.
function getHomePage(rowId, page, opts) {
  if (page > 1) return [];
  if (SHELVES.some(function (s) { return s[0] === rowId; })) {
    return html('/en/' + rowId, 9000).then(parseCards);
  }
  return [];
}

function popular(opts) {
  var page = (opts && opts.page) || 1;
  if (page > 1) return Promise.resolve([]);
  return html('/en/romance', 9000).then(parseCards);
}

function search(query, page, opts) {
  var term = String(query || '').trim();
  if (!term) return popular(opts);
  var path = '/en/search?keyword=' + encodeURIComponent(term) +
    '&page=' + ((page && page > 0) ? page : 1);
  return html(path, 9000).then(parseCards);
}

// Series list pages carry the episode hrefs. The episode SLUG is part of the
// URL, so viewer links must be read, never constructed from title_no alone.
function parseEpisodes(page) {
  var out = [];
  var re = /href="(https:\/\/www\.webtoons\.com\/en\/[a-z-]+\/[a-z0-9-]+\/[a-z0-9-]+\/viewer\?title_no=\d+&(?:amp;)?episode_no=(\d+))"/g;
  var m;
  while ((m = re.exec(page)) !== null) {
    var number = Number(m[2]);
    if (!number) continue;
    out.push({
      id: 'ep-' + number,
      title: 'Episode ' + number,
      number: number,
      url: decode(m[1]),
      date: ''
    });
  }
  return out;
}

function detailPath(url) { return String(url || '').replace(SITE, ''); }

function getDetail(url, opts) {
  var path = detailPath(url);
  return html(path, 9000).then(function (page) {
    var title = pick(/<title>([^<|]*)/, page);
    var cover = pick(/<meta property="og:image" content="([^"]+)"/, page);
    var description = pick(/<meta property="og:description" content="([^"]+)"/, page);
    var chapters = parseEpisodes(page);
    return {
      id: pick(/title_no=(\d+)/, path) || path,
      title: title || 'WEBTOON',
      url: url,
      type: 'manga',
      cover: cover,
      description: description,
      status: 'Ongoing',
      genres: [],
      authors: [],
      chapters: chapters,
      episodes: chapters
    };
  });
}

function getEpisodes(url, opts) {
  var path = detailPath(url);
  var pages = [];
  for (var i = 1; i <= MAX_EPISODE_PAGES; i++) {
    pages.push(html(path + (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + i, 9000)
      .then(parseEpisodes)
      .catch(function () { return []; }));
  }
  return Promise.all(pages).then(function (lists) {
    var seen = {};
    var all = [];
    for (var i = 0; i < lists.length; i++) {
      for (var j = 0; j < lists[i].length; j++) {
        var ep = lists[i][j];
        if (seen[ep.number]) continue;
        seen[ep.number] = true;
        all.push(ep);
      }
    }
    all.sort(function (a, b) { return b.number - a.number; });
    return all;
  });
}

// A chapter's `url` is the exact viewer href parsed from the series page.
// Panels are the <img class="_images" data-url="..."> inside #_imageList;
// the page contains hundreds of OTHER pstatic thumbnails, so the container
// matters — a whole-page image regex would fill the reader with recommendations.
function getPages(chapterUrl) {
  var path = detailPath(chapterUrl);
  return html(path, 9000).then(function (page) {
    var start = page.indexOf('id="_imageList"');
    if (start < 0) throw new Error('WEBTOON: no image list in viewer');
    var end = page.indexOf('</div>', start);
    var block = page.slice(start, end < 0 ? page.length : end);
    var out = [];
    var re = /<img\b[^>]*data-url="([^"]+)"/g;
    var m;
    while ((m = re.exec(block)) !== null) {
      var image = decode(m[1]);
      if (!/^https:\/\/[^\s]+\.pstatic\.net\//.test(image)) continue;
      out.push({url: image, headers: {Referer: SITE + '/'}});
    }
    if (!out.length) throw new Error('WEBTOON: no readable panels in viewer');
    return out;
  });
}
