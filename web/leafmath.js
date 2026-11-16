/*
 * Leaf math engine: Antinote-style line arithmetic for #math regions.
 * Pure logic, no DOM. Works in the browser (global `LeafMath`) and in node (module.exports).
 *
 *   const engine = LeafMath.createEngine(mathjs, rates)   // rates: {date, rates:{USD:1.1,...}} base EUR, or null
 *   const region = engine.evaluateRegion(lines)            // -> {lines:[{text, kind, answer}], usedCurrency, ratesDate}
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.LeafMath = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Currencies are registered as math.js units under a private prefix so they can never
  // clash with built-in units or functions (e.g. a code that matches a unit name).
  var CUR = 'LEAFCUR';
  var RESERVED = new Set(['ans', 'total', 'in', 'to', 'of', 'pi', 'e', 'i', 'true', 'false', 'null',
    'undefined', 'infinity', 'nan', 'end', 'mod', 'and', 'or', 'not', 'xor', 'phi', 'tau']);

  var intFmt = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  var sigFmt = new Intl.NumberFormat('en-US', { maximumSignificantDigits: 6 });
  var curFmt = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  /** Thousands separators; integers exact, other numbers up to 6 significant digits. */
  function formatNumber(x) {
    if (typeof x !== 'number' || !isFinite(x)) return null;
    x = x + 0; // normalise -0
    var ax = Math.abs(x);
    if (Number.isInteger(x) && ax < 1e15) return intFmt.format(x);
    var p = Number(x.toPrecision(6));
    if (p !== 0 && (Math.abs(p) >= 1e15 || Math.abs(p) < 1e-6)) return String(p);
    return sigFmt.format(p);
  }

  function formatCurrency(x, code) {
    if (typeof x !== 'number' || !isFinite(x)) return null;
    var s = curFmt.format(x + 0);
    if (s === '-0.00') s = '0.00';
    return s + ' ' + code;
  }

  /** Label text -> variable name: lowercase, spaces -> "_" (e.g. "Monthly rent" -> monthly_rent). */
  function labelToVar(label) {
    var s = label.toLowerCase().replace(/[^a-z0-9_\s]/g, ' ').trim().replace(/\s+/g, '_');
    if (!/^[a-z_][a-z0-9_]*$/.test(s)) return null;
    return s;
  }

  function createEngine(mathLib, rates) {
    var m = mathLib.create(mathLib.all);
    var codes = new Set();
    var ratesDate = null;

    if (rates && rates.rates && typeof rates.rates === 'object') {
      try {
        m.createUnit(CUR + 'EUR');
        codes.add('EUR');
        Object.keys(rates.rates).forEach(function (k) {
          var c = String(k).toUpperCase();
          var r = Number(rates.rates[k]);
          if (!/^[A-Z]{3}$/.test(c) || c === 'EUR' || !(r > 0) || !isFinite(r)) return;
          m.createUnit(CUR + c, { definition: String(1 / r) + ' ' + CUR + 'EUR' });
          codes.add(c);
        });
        ratesDate = rates.date || null;
      } catch (err) {
        codes.clear();
        ratesDate = null;
      }
      if (!codes.has('SGD')) { /* $ will simply fail to evaluate */ }
    }

    // Harden the evaluator (documents are AI-written): keep a private evaluate, disable the rest.
    var evaluate = m.evaluate;
    function disabled() { throw new Error('disabled'); }
    m.import({
      'import': disabled, createUnit: disabled, evaluate: disabled, parse: disabled,
      simplify: disabled, derivative: disabled, compile: disabled, resolve: disabled,
      reviver: disabled, replacer: disabled
    }, { override: true });

    function isCurrencyUnit(v) {
      return m.isUnit(v) && v.value !== null && v.units.length === 1 && v.units[0].power === 1 &&
        v.units[0].unit.name.indexOf(CUR) === 0;
    }

    /** Rewrite Leaf's friendly syntax into math.js syntax. Returns {expr, codes:Set, target}. */
    function preprocess(input) {
      var s = input;
      // 1,200 -> 1200 (only digit groups of exactly three)
      s = s.replace(/(\d),(?=\d{3}(?!\d))/g, '$1');
      // 1.5k -> 1500
      s = s.replace(/(?<![A-Za-z_\d.])(\d+(?:\.\d+)?|\.\d+)k(?![A-Za-z0-9_])/g, function (_, n) {
        return String(Number((Number(n) * 1000).toPrecision(15)));
      });
      // 20% of 450 -> (20 / 100) * 450
      s = s.replace(/(\d+(?:\.\d+)?)\s*%\s*of(?![A-Za-z0-9_])/gi, '($1 / 100) *');
      // $ always means SGD: $50, 50$, "in $"
      s = s.replace(/\$\s*(\d+(?:\.\d+)?)/g, ' ($1 ' + CUR + 'SGD) ');
      s = s.replace(/(\d+(?:\.\d+)?)\s*\$/g, ' ($1 ' + CUR + 'SGD) ');
      s = s.replace(/\$/g, ' ' + CUR + 'SGD ');
      // Three-letter ISO codes, case-insensitive, only those we have rates for.
      s = s.replace(/(?<![A-Za-z_])([A-Za-z]{3})(?![A-Za-z0-9_])/g, function (w, c) {
        var u = c.toUpperCase();
        return codes.has(u) ? CUR + u : w;
      });
      var used = new Set();
      var re = new RegExp(CUR + '([A-Z]{3})', 'g'), mm;
      while ((mm = re.exec(s))) used.add(mm[1]);
      var t = new RegExp('(?:^|[^A-Za-z0-9_])(?:in|to)\\s+\\(?\\s*' + CUR + '([A-Z]{3})\\s*\\)?\\s*$').exec(s);
      return { expr: s, codes: used, target: t ? t[1] : null };
    }

    /** Format a math.js value for display, or null if it shouldn't be shown. */
    function format(v) {
      if (typeof v === 'number') return formatNumber(v);
      if (m.isUnit(v)) {
        if (v.value === null) return null;
        if (isCurrencyUnit(v)) {
          var name = v.units[0].unit.name;
          return formatCurrency(v.toNumber(name), name.slice(CUR.length));
        }
        var str = m.format(v, { precision: 6 });
        var lead = /^(-?)(\d+)(\.\d+)?(?![\de])/.exec(str);
        if (lead) {
          str = lead[1] + intFmt.format(Number(lead[2])) + (lead[3] || '') + str.slice(lead[0].length);
        }
        return str.replace(new RegExp(CUR + '([A-Z]{3})', 'g'), '$1');
      }
      if (m.isBigNumber && m.isBigNumber(v)) return formatNumber(v.toNumber());
      if (m.isFraction && m.isFraction(v)) return formatNumber(m.number(v));
      return null; // booleans, matrices, functions, complex, strings: show nothing
    }

    function union(a, b) { var s = new Set(a); b.forEach(function (x) { s.add(x); }); return s; }

    function evaluateRegion(lines) {
      var scope = new Map();
      var varCodes = new Map(); // variable -> Set of currency codes it carries
      var ans; var ansCodes = new Set();
      var block = []; // answers since the last blank line: {value, codes}
      var usedCurrency = false;

      function blockTotal() {
        if (!block.length) return { value: 0, codes: new Set() };
        try {
          var v = block[0].value, c = new Set(block[0].codes);
          for (var k = 1; k < block.length; k++) { v = m.add(v, block[k].value); c = union(c, block[k].codes); }
          if (c.size > 1 && isCurrencyUnit(v)) v = v.to(CUR + 'SGD');
          return { value: v, codes: c };
        } catch (e) { return null; }
      }

      function run(expr) {
        var pre = preprocess(expr);
        if (!pre.expr.trim()) return null;
        if (pre.codes.size && codes.size) usedCurrency = true;
        if (ans !== undefined) scope.set('ans', ans); else scope.delete('ans');
        var tot = blockTotal();
        if (tot) scope.set('total', tot.value); else scope.delete('total');
        // Which currencies does this line involve (literally or via variables)?
        var lineCodes = new Set(pre.codes);
        var ids = pre.expr.match(/[A-Za-z_][A-Za-z0-9_]*/g) || [];
        var usesTotal = false;
        ids.forEach(function (id) {
          if (id === 'ans') lineCodes = union(lineCodes, ansCodes);
          else if (id === 'total') { usesTotal = true; if (tot) lineCodes = union(lineCodes, tot.codes); }
          else if (varCodes.has(id)) lineCodes = union(lineCodes, varCodes.get(id));
        });
        var v;
        try { v = evaluate(pre.expr, scope); } catch (e) { return null; }
        if (v && v.isResultSet) return null;
        if (typeof v === 'function') return null;
        try {
          if (isCurrencyUnit(v)) {
            if (pre.target) v = v.to(CUR + pre.target);
            else if (lineCodes.size > 1) v = v.to(CUR + 'SGD');
          }
        } catch (e) { return null; }
        var shown = format(v);
        if (shown === null) return null;
        if (isCurrencyUnit(v)) lineCodes = new Set([v.units[0].unit.name.slice(CUR.length)]);
        return { value: v, shown: shown, codes: lineCodes, usesTotal: usesTotal };
      }

      function define(name, res) {
        if (!name || RESERVED.has(name) || codes.has(name.toUpperCase()) || name.indexOf(CUR.toLowerCase()) === 0) return;
        scope.set(name, res.value);
        varCodes.set(name, res.codes);
      }

      var out = lines.map(function (raw) {
        var line = String(raw).replace(/\r$/, '');
        var t = line.trim();
        if (!t) { block = []; return { text: line, kind: 'blank', answer: null }; }
        if (/^#{1,6}\s/.test(t)) return { text: line, kind: 'heading', answer: null };
        if (t.indexOf('//') === 0) return { text: line, kind: 'comment', answer: null };

        var wantsAnswer = /=\s*$/.test(line) && !/(==|[<>!]=)\s*$/.test(line);
        var body = wantsAnswer ? line.replace(/=\s*$/, '') : line;
        var label = null;
        var ci = body.lastIndexOf(':');
        if (ci >= 0) { label = body.slice(0, ci); body = body.slice(ci + 1); }
        body = body.replace(/^\s*[-*+]\s+/, '');
        var name = label !== null ? labelToVar(label) : null;

        if (!wantsAnswer) {
          if (label !== null) {
            // "rent: 1800" defines rent silently.
            if (!body.trim()) return { text: line, kind: 'text', answer: null };
            var r = run(body);
            if (r) define(name, r);
            return { text: line, kind: 'text', answer: null };
          }
          var asg = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)\s*(.+)$/.exec(body);
          if (asg) {
            var r2 = run(asg[2]);
            if (r2) define(asg[1], r2);
          }
          return { text: line, kind: 'text', answer: null };
        }

        var res = run(body);
        if (!res) return { text: line, kind: 'text', answer: null };
        ans = res.value;
        ansCodes = res.codes;
        if (!res.usesTotal) block.push({ value: res.value, codes: res.codes });
        define(name, res);
        return { text: line, kind: 'answer', answer: res.shown };
      });

      return { lines: out, usedCurrency: usedCurrency, ratesDate: ratesDate };
    }

    return { evaluateRegion: evaluateRegion, hasRates: codes.size > 0, ratesDate: ratesDate };
  }

  /**
   * Split markdown source into normal markdown and #math regions. Code fences are respected
   * (a "#math" line inside a code block is just code). Returns {source, regions} where each
   * region's lines are replaced in `source` by a standalone placeholder paragraph.
   */
  function extractRegions(text, placeholder) {
    var lines = text.split('\n');
    var out = [], regions = [];
    var fence = null;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (fence) {
        out.push(line);
        var close = /^ {0,3}(`{3,}|~{3,})\s*$/.exec(line);
        if (close && close[1][0] === fence.ch && close[1].length >= fence.len) fence = null;
        continue;
      }
      var open = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (open && !(open[1][0] === '`' && line.slice(open[0].length).indexOf('`') >= 0)) {
        fence = { ch: open[1][0], len: open[1].length };
        out.push(line);
        continue;
      }
      if (line.trim().toLowerCase() === '#math') {
        var j = i + 1;
        while (j < lines.length && lines[j].trim().toLowerCase() !== '#endmath') j++;
        regions.push(lines.slice(i + 1, j));
        out.push('', placeholder(regions.length - 1), '');
        i = j; // skip the #endmath line too (or run to EOF)
        continue;
      }
      out.push(line);
    }
    return { source: out.join('\n'), regions: regions };
  }

  return {
    createEngine: createEngine,
    extractRegions: extractRegions,
    formatNumber: formatNumber,
    formatCurrency: formatCurrency,
    labelToVar: labelToVar
  };
});
