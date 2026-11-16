// Plain node tests for web/leafmath.js, using the same vendored math.js the app ships.
// Run: node tests/math.test.js
'use strict';
const path = require('path');
const assert = require('assert');
const mathjs = require(path.join(__dirname, '../web/vendor/math.min.js'));
const LeafMath = require(path.join(__dirname, '../web/leafmath.js'));

// Fixed sample rates (base EUR), like the cached Frankfurter response.
const RATES = { date: '2026-11-13', base: 'EUR', rates: { EUR: 1, USD: 1.1052, SGD: 1.4236, JPY: 176.83, GBP: 0.83559, MYR: 4.5175, TRY: 55.6667 } };

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failed++; console.log('FAIL', name, '\n   ', e.message); }
}

const withRates = LeafMath.createEngine(mathjs, RATES);
const noRates = LeafMath.createEngine(mathjs, null);

/** Evaluate a region; return the answers (null where nothing is shown). */
function answers(text, engine = withRates) {
  return engine.evaluateRegion(text.split('\n')).lines.map(l => l.answer);
}
function last(text, engine) { const a = answers(text, engine); return a[a.length - 1]; }

// --- Basic line rules ---
test('line ending in = shows answer', () => assert.strictEqual(last('12 + 8 ='), '20'));
test('calculation without = still shows its answer', () => assert.strictEqual(last('12 + 8'), '20'));
test('no =: variable definition stays silent', () => assert.strictEqual(last('rent: 1800'), null));
test('no =: variable then use', () => assert.strictEqual(last('rent: 1800\nrent * 12'), '21,600'));
test('no =: labelled calculation shows and defines', () => assert.strictEqual(last('Lunch: 12 + 8\nlunch * 2'), '40'));
test('no =: bare known variable shows its value', () => assert.strictEqual(last('rent: 1800\nrent'), '1,800'));
test('no =: bare number shows nothing', () => assert.strictEqual(last('1800'), null));
test('no =: prose shows nothing', () => assert.strictEqual(last('Buy milk and follow-up with Sam'), null));
test('no =: unknown single word shows nothing', () => assert.strictEqual(last('groceries'), null));
test('no =: unit conversion', () => assert.strictEqual(last('3 hours in minutes'), last('3 hours in minutes =')));
test('no =: percent of', () => assert.strictEqual(last('20% of 450'), '90'));
test('no =: total counts answers without =', () => assert.strictEqual(last('10 + 5\n2 * 10\ntotal'), '35'));
test('no =: currency', () => assert.strictEqual(last('$100 in usd'), last('100 sgd in usd =')));
test('label: Lunch: 12 + 8 = -> 20', () => assert.strictEqual(last('Lunch: 12 + 8 ='), '20'));
test('label becomes variable', () => assert.strictEqual(last('Lunch: 12 + 8 =\nlunch * 2 ='), '40'));
test('multi-word label variable', () => assert.strictEqual(last('Monthly rent: 1800 =\nmonthly_rent * 12 ='), '21,600'));
test('text before LAST colon is label', () => assert.strictEqual(last('Trip: day 1: 5 * 3 =\ntrip_day_1 ='), '15'));
test('silent variable definition (acceptance)', () => {
  const a = answers('rent: 1800\nrent * 12 =');
  assert.deepStrictEqual(a, [null, '21,600']);
});
test('assignment form x = 5 is silent', () => assert.deepStrictEqual(answers('x = 5\nx * 3 ='), [null, '15']));
test('ans is previous answer', () => assert.strictEqual(last('10 * 10 =\nans / 4 ='), '25'));
test('total sums answers since last blank line', () => {
  assert.deepStrictEqual(answers('a: 10 =\nb: 20 =\n\nc: 1 =\nd: 2 =\ntotal ='), ['10', '20', null, '1', '2', '3']);
});
test('total with no answers yet is 0', () => assert.strictEqual(last('total ='), '0'));
test('silent definitions do not count toward total', () => assert.strictEqual(last('rent: 1800\n5 =\ntotal ='), '5'));
test('operators + - * / ^ and brackets', () => assert.strictEqual(last('(2 + 3) * 4 ^ 2 / 8 - 1 ='), '9'));
test('% modulo/percent per math.js', () => assert.strictEqual(last('50 + 10% ='), '55'));
test('20% of 450', () => assert.strictEqual(last('20% of 450 ='), '90'));
test('1,200 thousands separators', () => assert.strictEqual(last('1,200 + 1,000,000 ='), '1,001,200'));
test('1.5k', () => assert.strictEqual(last('1.5k * 2 ='), '3,000'));
test('5 km in miles', () => assert.strictEqual(last('5 km in miles ='), '3.10686 miles'));
test('3 hours in minutes', () => assert.strictEqual(last('3 hours in minutes ='), '180 minutes'));
test('x to y conversion', () => assert.strictEqual(last('2 kg to g ='), '2,000 g'));
test('errors show nothing', () => {
  assert.deepStrictEqual(answers('hello world =\n1 / =\nfoo(3) =\n5 km + 3 kg ='), [null, null, null, null]);
});
test('booleans show nothing', () => assert.strictEqual(last('5 > 3 ='), null));
test('division by zero shows nothing', () => assert.strictEqual(last('1/0 ='), null));
test('dangerous functions disabled', () => {
  assert.strictEqual(last('evaluate("1+1") ='), null);
  assert.strictEqual(last('import({}) ='), null);
  assert.strictEqual(last('createUnit("foo") ='), null);
});
test('bulleted line', () => assert.strictEqual(last('- Coffee: 4.5 * 5 ='), '22.5'));
test('blank/heading/comment kinds', () => {
  const r = withRates.evaluateRegion(['# Budget', '// note', '', '1+1 =']).lines.map(l => l.kind);
  assert.deepStrictEqual(r, ['heading', 'comment', 'blank', 'answer']);
});
test('fresh scope per region', () => {
  answers('rent: 1800');
  assert.strictEqual(last('rent * 12 ='), null);
});

// --- Number formatting ---
test('thousands separator', () => assert.strictEqual(LeafMath.formatNumber(1234567), '1,234,567'));
test('6 significant digits, trailing zeros removed', () => {
  assert.strictEqual(LeafMath.formatNumber(1 / 3), '0.333333');
  assert.strictEqual(LeafMath.formatNumber(2.5), '2.5');
  assert.strictEqual(LeafMath.formatNumber(1234.5678), '1,234.57');
  assert.strictEqual(LeafMath.formatNumber(0.1 + 0.2), '0.3');
});
test('negative numbers', () => assert.strictEqual(last('5 - 12.5 ='), '-7.5'));

// --- Currency ---
test('100 usd in sgd -> 2 dp with code', () => assert.match(last('100 usd in sgd ='), /^\d{1,3}(,\d{3})*\.\d{2} SGD$/));
test('100 usd to sgd', () => assert.strictEqual(last('100 usd to sgd ='), last('100 usd in sgd =')));
test('case-insensitive codes', () => assert.strictEqual(last('100 USD in SGD ='), last('100 usd in sgd =')));
test('$100 in usd == 100 sgd in usd (acceptance)', () => {
  const a = last('$100 in usd =');
  assert.strictEqual(a, last('100 sgd in usd ='));
  assert.strictEqual(a, '77.63 USD');
});
test('50$ means SGD', () => assert.strictEqual(last('50$ in usd ='), last('$50 in usd =')));
test('$ alone as target', () => assert.strictEqual(last('100 usd in $ ='), last('100 usd in sgd =')));
test('single currency keeps its code', () => assert.strictEqual(last('20 eur + 5 eur ='), '25.00 EUR'));
test('mixed currency with no target -> SGD', () => assert.match(last('$50 + 20 eur ='), /^\d+\.\d{2} SGD$/));
test('mixed currency with target', () => assert.match(last('$50 + 20 eur in usd ='), /^\d+\.\d{2} USD$/));
test('mixed, eur first, no target -> SGD', () => assert.match(last('20 eur + $50 ='), / SGD$/));
test('currency thousands separators', () => assert.strictEqual(last('$1,234.5 ='), '1,234.50 SGD'));
test('currency * number', () => assert.strictEqual(last('$12.50 * 4 ='), '50.00 SGD'));
test('currency with k', () => assert.strictEqual(last('$1.5k ='), '1,500.00 SGD'));
test('currency variables', () => assert.strictEqual(last('hotel: 300 eur\nflight: $800\nhotel + flight ='), last('300 eur + $800 =')));
test('total over mixed currencies -> SGD', () => assert.match(last('$10 =\n10 usd =\ntotal ='), / SGD$/));
test('currency + plain number shows nothing', () => assert.strictEqual(last('100 usd + 5 ='), null));
test('ISO code that clashes with a word (try)', () => assert.match(last('100 try in sgd ='), / SGD$/));
test('5000 jpy', () => assert.match(last('5000 jpy in sgd ='), /^\d+\.\d{2} SGD$/));
test('no rates -> currency lines show nothing', () => {
  assert.strictEqual(last('100 usd in sgd =', noRates), null);
  assert.strictEqual(last('$50 =', noRates), null);
  assert.strictEqual(last('1 + 1 =', noRates), '2');
});
test('usedCurrency only when a currency is used', () => {
  assert.strictEqual(withRates.evaluateRegion(['1 + 1 =']).usedCurrency, false);
  const r = withRates.evaluateRegion(['$5 =']);
  assert.strictEqual(r.usedCurrency, true);
  assert.strictEqual(r.ratesDate, '2026-11-13');
});
test('label that is a currency code stays a currency', () => assert.strictEqual(last('usd: 5\nusd * 2 ='), '2.00 USD'));

// --- Region extraction ---
test('#math ... #endmath extracted, rest untouched', () => {
  const src = 'Cost: 5 + 5 =\n#math\nrent: 1800\nrent * 12 =\n#endmath\nafter';
  const ex = LeafMath.extractRegions(src, k => 'PH' + k);
  assert.deepStrictEqual(ex.regions, [['rent: 1800', 'rent * 12 =']]);
  assert.strictEqual(ex.source, 'Cost: 5 + 5 =\n\nPH0\n\nafter');
});
test('#math to end of file', () => {
  const ex = LeafMath.extractRegions('a\n#math\n1+1 =\n\n2 =', k => 'PH' + k);
  assert.deepStrictEqual(ex.regions, [['1+1 =', '', '2 =']]);
});
test('#math inside a code fence is ignored', () => {
  const ex = LeafMath.extractRegions('```\n#math\n1+1 =\n```\n', k => 'PH' + k);
  assert.strictEqual(ex.regions.length, 0);
});
test('doc without #math has no regions', () => {
  assert.strictEqual(LeafMath.extractRegions('Cost: 5 + 5 =', k => 'PH' + k).regions.length, 0);
});

// --- Whole-document answers (native editor) ---
function docAnswers(text, engine = withRates) { return LeafMath.documentAnswers(engine, text); }
test('documentAnswers: #math region, answers by source line', () => {
  assert.deepStrictEqual(docAnswers('# Note\n#math\nrent: 1800\nrent * 12 ='), [{ line: 3, answer: '21,600' }]);
});
test('documentAnswers: "# math" / "# endmath" with a space also work; other headings do not', () => {
  assert.deepStrictEqual(docAnswers('# Math\nrent: 1800\nrent * 12 =\n# endmath\n5 + 5 =\n\n# Maths notes\n1 + 1 ='), [{ line: 2, answer: '21,600' }]);
});
test('documentAnswers: = lines outside regions get nothing', () => {
  assert.deepStrictEqual(docAnswers('Cost: 5 + 5 =\n#math\n1 + 1 =\n#endmath\n2 + 2 ='), [{ line: 2, answer: '2' }]);
});
test('documentAnswers: ```math fence', () => {
  assert.deepStrictEqual(docAnswers('intro =\n```math\na: 2\na * 3 =\n```\n4 * 4 ='), [{ line: 3, answer: '6' }]);
});
test('documentAnswers: other fences and #math inside fences ignored', () => {
  assert.deepStrictEqual(docAnswers('```js\n1 + 1 =\n```\n~~~\n#math\n2 + 2 =\n~~~'), []);
});
test('documentAnswers: unclosed ```math fence runs to EOF', () => {
  assert.deepStrictEqual(docAnswers('```math\n3 * 3 ='), [{ line: 1, answer: '9' }]);
});
test('documentAnswers: two regions have separate scopes', () => {
  assert.deepStrictEqual(docAnswers('#math\nx: 4\nx * 2 =\n#endmath\ntext\n#math\nx * 2 =\n5 ='),
    [{ line: 2, answer: '8' }, { line: 7, answer: '5' }]);
});
test('documentAnswers: errors and empty doc show nothing', () => {
  assert.deepStrictEqual(docAnswers('#math\nhello =\n1 / =\n'), []);
  assert.deepStrictEqual(docAnswers(''), []);
});
test('documentAnswers matches evaluateRegion (same engine as reading view)', () => {
  const region = 'hotel: 300 eur\nflight: $800\nhotel + flight =\ntotal =';
  const viaRegion = answers(region);
  const viaDoc = docAnswers('#math\n' + region);
  assert.deepStrictEqual(viaDoc.map(a => a.answer), viaRegion.filter(a => a !== null));
});
test('documentAnswers: CRLF line endings', () => {
  assert.deepStrictEqual(docAnswers('#math\r\n1 + 2 =\r\n'), [{ line: 1, answer: '3' }]);
});

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
