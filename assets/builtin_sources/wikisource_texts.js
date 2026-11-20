// ClearCut built-in text source: Wikisource (public-domain texts).
// Plays, speeches, poetry, historical documents, treaties and philosophy from
// Wikisource, the Wikimedia Foundation's library of source texts. Complements
// "Project Gutenberg (free books)", which focuses on novels.
// Everything here is public domain or freely licensed; check your local
// copyright rules outside your own country.
//
// LNReader plugin format (CommonJS, `exports.default`), run by the app's
// LNReader harness — same contract as gutenberg.js.

var fetchApi = require('@libs/fetch').fetchApi;

var SITE = 'https://en.wikisource.org';
var API = SITE + '/w/api.php';

function getJson(url) {
  return fetchApi(url, { headers: { 'User-Agent': 'ClearCut/1.0 (reading app)' } })
    .then(function (r) {
      if (!r.ok) throw new Error('Wikisource: HTTP ' + r.status);
      return r.json();
    });
}

// The MediaWiki API occasionally answers 503 under load; one retry covers it.
function getJsonRetry(url) {
  return getJson(url).catch(function () { return getJson(url); });
}

function qs(params) {
  var parts = [];
  for (var k in params) {
    if (!Object.prototype.hasOwnProperty.call(params, k)) continue;
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
  }
  parts.push('format=json');
  parts.push('formatversion=2');
  return API + '?' + parts.join('&');
}

function stripTags(html) {
  return String(html || '')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&#160;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function toNovel(page) {
  return {
    name: String(page.title || '').replace(/_/g, ' '),
    path: page.title,
    cover: undefined,
  };
}

function searchPages(term, limit) {
  var url = qs({
    action: 'query',
    list: 'search',
    srsearch: String(term || ''),
    srnamespace: 0,
    srlimit: limit || 20,
  });
  return getJsonRetry(url).then(function (d) {
    var hits = (d && d.query && d.query.search) || [];
    return hits.map(toNovel).filter(function (n) { return !!n.path; });
  });
}

// The reader's HTML, with Wikisource's chrome removed: edit links, the
// header/ footer navigation templates, and the sister-project boxes.
function cleanArticle(html) {
  return String(html || '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<div[^>]*class="[^"]*(ws-noexport|noprint|licenseContainer|ws-summary|header_notes)[^"]*"[^>]*>[\s\S]*?<\/div>/gi, '')
    .replace(/<span[^>]*class="[^"]*mw-editsection[^"]*"[^>]*>[\s\S]*?<\/span>/gi, '')
    .replace(/<table[^>]*class="[^"]*(ws-noexport|noprint)[^"]*"[^>]*>[\s\S]*?<\/table>/gi, '')
    .replace(/<a[^>]*class="[^"]*mw-selflink[^"]*"[^>]*>/gi, '<span>')
    .trim();
}

function parsePage(title) {
  var url = qs({
    action: 'parse',
    page: title,
    prop: 'text|displaytitle',
    redirects: 1,
    disableeditsection: 1,
  });
  return getJsonRetry(url).then(function (d) {
    if (!d || !d.parse) throw new Error('Wikisource: page not found');
    return {
      title: stripTags(d.parse.displaytitle || d.parse.title || title),
      html: cleanArticle(d.parse.text),
    };
  });
}

// Subpages of a work are its chapters when it is split that way (most long
// works are); otherwise the page itself is one chapter.
function subpages(title) {
  var url = qs({
    action: 'query',
    list: 'allpages',
    apprefix: title + '/',
    apnamespace: 0,
    aplimit: 100,
  });
  return getJsonRetry(url).then(
    function (d) {
      var pages = (d && d.query && d.query.allpages) || [];
      return pages.map(function (p) { return p.title; });
    },
    function () { return []; }
  );
}

var plugin = {
  id: 'clearcut_wikisource',
  name: 'Wikisource (free texts)',
  site: SITE,
  version: '1.0.0',
  icon: SITE + '/favicon.ico',

  popularNovels: function (page, opts) {
    // "Featured texts" is Wikisource's curated front shelf — genuinely good
    // reading rather than an arbitrary pile of stubs.
    var url = qs({
      action: 'query',
      list: 'categorymembers',
      cmtitle: 'Category:Featured texts',
      cmnamespace: 0,
      cmlimit: 50,
    });
    return getJsonRetry(url).then(function (d) {
      var pages = (d && d.query && d.query.categorymembers) || [];
      return pages.map(toNovel).filter(function (n) { return !!n.path; });
    });
  },

  searchNovels: function (term, page) {
    return searchPages(term, 20);
  },

  parseNovel: function (path) {
    var title = String(path).replace(/_/g, ' ');
    return Promise.all([parsePage(title), subpages(title)]).then(function (res) {
      var body = res[0];
      var subs = res[1];
      var chapters = subs.length > 1
        ? subs.map(function (t, i) {
            return { name: t.replace(title + '/', '').replace(/_/g, ' '), path: t, chapterNumber: i + 1 };
          })
        : [{ name: body.title || title, path: title, chapterNumber: 1 }];
      var summary = stripTags(body.html).substring(0, 400);
      return {
        path: title,
        name: body.title || title,
        cover: undefined,
        author: undefined,
        summary: summary,
        status: 'Completed',
        genres: [],
        chapters: chapters,
      };
    });
  },

  parseChapter: function (chapterPath) {
    return parsePage(String(chapterPath).replace(/_/g, ' '))
      .then(function (p) { return p.html; })
      .catch(function () { return ''; });
  },
};

exports.default = plugin;
