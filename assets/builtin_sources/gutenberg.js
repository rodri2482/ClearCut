// ClearCut built-in novel source: Project Gutenberg (public-domain books).
// LNReader plugin format (CommonJS, `exports.default`), run by the app's
// LNReader harness. Catalogue + covers come from the Gutendex API
// (https://gutendex.com), the text from gutenberg.org's HTML editions.
// Every book here is public domain in the United States; check your local
// copyright rules before reading outside the US.

var fetchApi = require('@libs/fetch').fetchApi;

var API = 'https://gutendex.com/books/';
var SITE = 'https://www.gutenberg.org';
// Official mirror (PGLAF). Used for covers, and for book text whenever
// gutenberg.org is down for maintenance.
var MIRROR = 'https://gutenberg.pglaf.org';

// One book's HTML, kept so opening chapter after chapter doesn't re-download it.
var cache = { id: null, html: null };

function getJson(url) {
  return fetchApi(url).then(function (r) {
    if (!r.ok) throw new Error('Gutenberg: HTTP ' + r.status);
    return r.json();
  });
}

// Gutendex is a free volunteer service and sometimes answers 503 under load:
// one retry fixes almost all of those.
function getJsonRetry(url) {
  return getJson(url).catch(function () { return getJson(url); });
}

// Tries each URL in turn and returns the first page that loads.
function firstText(urls) {
  var i = 0;
  function next() {
    if (i >= urls.length) return Promise.reject(new Error('Gutenberg: book text unavailable'));
    var url = urls[i++];
    return getText(url).then(function (t) {
      if (!t || /Temporarily Down for Maintenance/.test(t)) return next();
      return t;
    }, next);
  }
  return next();
}

function getText(url) {
  return fetchApi(url).then(function (r) {
    if (!r.ok) throw new Error('Gutenberg: HTTP ' + r.status);
    return r.text();
  });
}

function bookId(path) {
  var m = String(path).match(/(\d+)/);
  return m ? m[1] : String(path);
}

function toNovel(b) {
  var f = b.formats || {};
  return {
    name: b.title,
    path: 'book/' + b.id,
    cover: MIRROR + '/cache/epub/' + b.id + '/pg' + b.id + '.cover.medium.jpg',
  };
}

function htmlUrl(b) {
  var f = b.formats || {};
  var keys = Object.keys(f);
  for (var i = 0; i < keys.length; i++) {
    if (keys[i].indexOf('text/html') === 0 && !/\.zip$/.test(f[keys[i]])) return f[keys[i]];
  }
  return SITE + '/ebooks/' + b.id + '.html.images';
}

// Splits a book's HTML body into chapters at its <h2> headings (Gutenberg's
// HTML editions mark chapters with h2). Books without them become one chapter.
function splitChapters(html) {
  var bodyMatch = html.match(/<body[^>]*>([\s\S]*)<\/body>/i);
  var body = bodyMatch ? bodyMatch[1] : html;
  var starts = [];
  var re = /<h2[\s>]/gi;
  var m;
  while ((m = re.exec(body)) !== null) starts.push(m.index);
  if (starts.length < 2) return [{ title: 'Full text', html: body }];
  var out = [];
  if (starts[0] > 0) out.push({ title: 'Opening', html: body.substring(0, starts[0]) });
  for (var i = 0; i < starts.length; i++) {
    var part = body.substring(starts[i], i + 1 < starts.length ? starts[i + 1] : body.length);
    var t = part.match(/<h2[^>]*>([\s\S]*?)<\/h2>/i);
    // Drop tags and printed page markers such as "{ix}" from the heading.
    var title = t ? t[1].replace(/<[^>]+>/g, ' ').replace(/\{[^}]*\}/g, ' ')
      .replace(/\s+/g, ' ').trim() : '';
    out.push({ title: title || 'Part ' + (i + 1), html: part });
  }
  return out;
}

function loadBook(id, meta) {
  if (cache.id === id && cache.html) return Promise.resolve(cache.html);
  var urls = [];
  if (meta) urls.push(htmlUrl(meta));
  urls.push(MIRROR + '/cache/epub/' + id + '/pg' + id + '-images.html');
  urls.push(SITE + '/cache/epub/' + id + '/pg' + id + '-images.html');
  return firstText(urls).then(function (html) {
    cache = { id: id, html: html };
    return html;
  });
}

var plugin = {
  id: 'clearcut_gutenberg',
  name: 'Project Gutenberg (free books)',
  site: SITE,
  version: '1.0.0',
  icon: SITE + '/gutenberg/pg-logo-129x80.png',

  popularNovels: function (page, opts) {
    var latest = opts && opts.showLatestNovels;
    var url = API + '?languages=en&page=' + (page || 1) + (latest ? '&sort=descending' : '');
    return getJsonRetry(url).then(function (d) { return (d.results || []).map(toNovel); });
  },

  searchNovels: function (term, page) {
    return getJsonRetry(API + '?search=' + encodeURIComponent(term) + '&page=' + (page || 1))
      .then(function (d) { return (d.results || []).map(toNovel); });
  },

  parseNovel: function (path) {
    var id = bookId(path);
    var meta = null;
    return getJsonRetry(API + id + '/').then(
      function (b) { meta = b; },
      function () { meta = null; } // details still open from the book itself
    ).then(function () {
      return loadBook(id, meta);
    }).then(function (html) {
      var parts = splitChapters(html);
      var t = html.match(/<title>([\s\S]*?)<\/title>/i);
      var htmlTitle = t ? t[1].replace(/\s*\|\s*Project Gutenberg\s*$/i, '').replace(/^The Project Gutenberg eBook of\s*/i, '').trim() : 'Book ' + id;
      var m = meta || {};
      var summary = (m.summaries && m.summaries[0]) || (m.subjects || []).join(' · ');
      return {
        path: path,
        name: m.title || htmlTitle,
        cover: MIRROR + '/cache/epub/' + id + '/pg' + id + '.cover.medium.jpg',
        author: (m.authors || []).map(function (a) { return a.name; }).join(', '),
        summary: summary,
        status: 'Completed',
        genres: (m.bookshelves || []).map(function (s) {
          return s.replace(/^Browsing:\s*/, '');
        }).slice(0, 6),
        chapters: parts.map(function (p, i) {
          return { name: p.title, path: 'book/' + id + '/' + i, chapterNumber: i + 1 };
        }),
      };
    });
  },

  parseChapter: function (chapterPath) {
    var m = String(chapterPath).match(/book\/(\d+)\/(\d+)/);
    if (!m) return Promise.resolve('');
    var index = parseInt(m[2], 10);
    return loadBook(m[1]).then(function (html) {
      var parts = splitChapters(html);
      return parts[index] ? parts[index].html : '';
    });
  },
};

exports.default = plugin;
