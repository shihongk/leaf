/* Leaf reading view. Swift calls window.leaf.render(payload); nothing else drives this page. */
(function () {
  'use strict';

  var content = document.getElementById('content');
  var mdBreaks = null;
  var md = null;
  var engine = null;
  var engineKey = null;
  var baseURL = 'file:///';
  var WIDTHS = { narrow: '640px', medium: '760px', wide: '1000px' };
  var PLACEHOLDER_RE = /<p>LEAFMATHREGION(\d+)X<\/p>\n?/g;

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function slugify(s) {
    return s.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-');
  }

  function buildMarkdown(breaks) {
    var m = window.markdownit({
      html: false,          // raw HTML in files never renders
      linkify: true,
      typographer: false,
      breaks: !!breaks,
      highlight: function (code, lang) {
        if (lang && window.hljs && hljs.getLanguage(lang)) {
          try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (e) { /* fall through */ }
        }
        return ''; // markdown-it escapes it
      }
    });
    if (window.markdownitTaskLists) {
      m.use(window.markdownitTaskLists, { enabled: true }); // enabled: no `disabled` attribute
      // Tag each task checkbox with its 0-based SOURCE line (token.map, mapped back through
      // env.lineMap when #math regions were swapped for placeholders).
      m.core.ruler.after('github-task-lists', 'leaf_task_lines', function (state) {
        var map = state.env && state.env.lineMap;
        var toks = state.tokens;
        for (var i = 0; i + 2 < toks.length; i++) {
          var li = toks[i];
          if (li.type !== 'list_item_open' || !li.map || (li.attrGet('class') || '').indexOf('task-list-item') < 0) continue;
          var kids = toks[i + 2].children;
          var box = kids && kids[0];
          if (!box || box.type !== 'html_inline' || box.content.indexOf('<input class="task-list-item-checkbox"') !== 0) continue;
          var line = map ? map[li.map[0]] : li.map[0];
          box.content = (typeof line === 'number' && line >= 0)
            ? box.content.replace('<input ', '<input data-line="' + line + '" ')
            : box.content.replace('<input ', '<input disabled ');
        }
      });
    }

    // Wide tables scroll inside their own box.
    m.renderer.rules.table_open = function () { return '<div class="table-wrap"><table>\n'; };
    m.renderer.rules.table_close = function () { return '</table></div>\n'; };

    // ```math fences are math regions.
    var defaultFence = m.renderer.rules.fence;
    m.renderer.rules.fence = function (tokens, idx, options, env, self) {
      var token = tokens[idx];
      var info = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
      if (info === 'math') {
        var lines = token.content.replace(/\n$/, '').split('\n');
        return renderMathRegion(lines);
      }
      return defaultFence(tokens, idx, options, env, self);
    };

    // Heading ids so in-page #anchors work.
    m.core.ruler.push('leaf_heading_ids', function (state) {
      var seen = {};
      for (var i = 0; i < state.tokens.length; i++) {
        var t = state.tokens[i];
        if (t.type !== 'heading_open') continue;
        var inline = state.tokens[i + 1];
        var slug = slugify(inline && inline.content ? inline.content : '') || 'section';
        if (seen[slug] !== undefined) { seen[slug]++; slug = slug + '-' + seen[slug]; } else seen[slug] = 0;
        t.attrSet('id', slug);
      }
    });
    return m;
  }

  function getEngine(rates) {
    if (!window.LeafMath || !window.math) return null;
    var key = rates ? (rates.date + ':' + Object.keys(rates.rates || {}).length) : 'none';
    if (engine && engineKey === key) return engine;
    try {
      engine = LeafMath.createEngine(window.math, rates || null);
      engineKey = key;
    } catch (e) {
      engine = null;
    }
    return engine;
  }

  function renderMathRegion(lines) {
    var eng = engine;
    var result;
    try {
      result = eng ? eng.evaluateRegion(lines) : null;
    } catch (e) {
      result = null;
    }
    if (!result) {
      result = { lines: lines.map(function (l) { return { text: l, kind: l.trim() ? 'text' : 'blank', answer: null }; }), usedCurrency: false };
    }
    var html = '<div class="math-block">';
    result.lines.forEach(function (l) {
      var cls = 'math-line';
      if (l.kind === 'blank') { html += '<div class="math-line blank">&#8203;</div>'; return; }
      if (l.kind === 'heading') cls += ' math-heading';
      if (l.kind === 'comment') cls += ' math-comment';
      if (l.answer !== null && l.answer !== undefined) {
        // Keep the "=" and the pill together on one line.
        var text = l.text.replace(/\s+$/, '');
        var cut = l.implicitEq ? text.search(/\S*$/) : text.search(/\S*\s*=$/);
        if (cut < 0) cut = text.length;
        // An auto-shown "=" (line typed without one) is display-only, drawn by CSS.
        var eq = l.implicitEq ? '<span class="math-eq"></span>' : '';
        html += '<div class="' + cls + ' has-answer">' + escapeHTML(text.slice(0, cut)) +
          '<span class="math-tail">' + escapeHTML(text.slice(cut)) + eq +
          '<span class="math-ans">' + escapeHTML(l.answer) + '</span></span></div>';
      } else {
        var shown = l.kind === 'heading' ? l.text.replace(/^\s*#{1,6}\s+/, '') : l.text;
        html += '<div class="' + cls + '">' + escapeHTML(shown) + '</div>';
      }
    });
    html += '</div>';
    if (result.usedCurrency && result.ratesDate) {
      html += '<div class="math-rates">Rates: ECB, ' + escapeHTML(result.ratesDate) + '</div>';
    }
    return '<div class="math-region">' + html + '</div>\n';
  }

  function hasScheme(s) { return /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s); }

  function resolve(href) {
    try { return new URL(href, baseURL).href; } catch (e) { return null; }
  }

  function fixUpLinksAndImages() {
    var imgs = content.querySelectorAll('img[src]');
    for (var i = 0; i < imgs.length; i++) {
      var src = imgs[i].getAttribute('src');
      if (!src || src.indexOf('//') === 0) continue;
      if (hasScheme(src) && !/^file:/i.test(src)) continue;
      var abs = resolve(src); // file:///folder/of/doc/images/x.png
      if (abs && /^file:/i.test(abs)) imgs[i].setAttribute('src', 'leaf-file:' + abs.slice(5));
    }
    var links = content.querySelectorAll('a[href]');
    for (var j = 0; j < links.length; j++) {
      var href = links[j].getAttribute('href');
      if (!href || href.charAt(0) === '#' || hasScheme(href)) continue;
      var a = resolve(href);
      if (a) links[j].setAttribute('href', a);
    }
  }

  function applySettings(s) {
    s = s || {};
    var root = document.documentElement.style;
    if (s.fontSize) root.setProperty('--font-size', s.fontSize + 'px');
    root.setProperty('--reading-width', WIDTHS[s.readingWidth] || WIDTHS.medium);
    document.body.classList.toggle('wrap-code', !!s.wrapCode);
    if (md === null || mdBreaks !== !!s.breaks) {
      md = buildMarkdown(!!s.breaks);
      mdBreaks = !!s.breaks;
    }
  }

  function maxScroll() {
    return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
  }

  function renderHTML(text) {
    var regions = [];
    var source = text;
    var env = {};
    if (window.LeafMath) {
      var ex = LeafMath.extractRegions(text, function (k) { return 'LEAFMATHREGION' + k + 'X'; });
      source = ex.source;
      regions = ex.regions;
      env.lineMap = ex.lineMap;
    }
    var html = md.render(source, env);
    if (regions.length) {
      html = html.replace(PLACEHOLDER_RE, function (all, k) {
        var r = regions[Number(k)];
        return r ? renderMathRegion(r) : '';
      });
    }
    return html;
  }

  function render(payload) {
    payload = payload || {};
    var prevY = window.scrollY;
    baseURL = payload.baseURL || baseURL;
    applySettings(payload.settings);
    getEngine(payload.rates);
    var html;
    try {
      html = renderHTML(String(payload.text || ''));
    } catch (e) {
      html = '<pre>' + escapeHTML(String(payload.text || '')) + '</pre>';
    }
    content.innerHTML = html;
    fixUpLinksAndImages();
    if (typeof payload.scrollFraction === 'number') {
      window.scrollTo(0, payload.scrollFraction * maxScroll());
    } else {
      window.scrollTo(0, Math.min(prevY, maxScroll()));
    }
    return { ok: true, scrollY: window.scrollY };
  }

  // In-page anchors scroll; everything else is handed to Swift's navigation policy,
  // which opens it in the default browser and never navigates this view.
  document.addEventListener('click', function (ev) {
    var a = ev.target.closest && ev.target.closest('a[href]');
    if (!a) return;
    var href = a.getAttribute('href');
    if (href && href.charAt(0) === '#') {
      ev.preventDefault();
      var id = decodeURIComponent(href.slice(1));
      var el = document.getElementById(id);
      if (el) el.scrollIntoView({ block: 'start' });
    }
  });

  function post(msg) {
    try { window.webkit.messageHandlers.leaf.postMessage(msg); } catch (e) { /* not hosted by Leaf */ }
  }

  // Click a task checkbox: Swift flips the [ ]/[x] in the source and re-renders.
  document.addEventListener('click', function (ev) {
    var t = ev.target;
    if (!t || !t.matches || !t.matches('input.task-list-item-checkbox[data-line]')) return;
    ev.preventDefault(); // the re-render shows the new state
    post({ type: 'toggleTask', line: Number(t.getAttribute('data-line')) });
  });

  // Double-click anywhere else on the page switches to the editor.
  document.addEventListener('dblclick', function (ev) {
    var t = ev.target;
    if (!t || !t.closest) return;
    if (t.closest('a, input, label')) return;
    // Scrollbars of code blocks / tables report the scroller itself as the target.
    if (t.classList.contains('table-wrap') || t.tagName === 'PRE') return;
    post({ type: 'dblclick' });
  });

  window.leaf = {
    render: render,
    scrollFraction: function () {
      var mx = maxScroll();
      return mx > 0 ? window.scrollY / mx : 0;
    }
  };
})();
