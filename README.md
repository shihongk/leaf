# Leaf

A small, fast Markdown reader for macOS. Open a `.md` file and see it properly formatted. Lines inside a `#math` region are calculated inline, Antinote-style.

- GitHub-style reading view, automatic light/dark, syntax-highlighted code, tables, task lists
- `Cmd+N` starts a blank note, `Cmd+E` toggles a plain-text editor, `Cmd+S` saves
- Reloads automatically when the file changes on disk
- Raw HTML and scripts in files are never run
- Works offline (all libraries are bundled)

## Install

Requires macOS 14 or later and Apple's Command Line Tools (no Xcode needed).

```bash
xcode-select --install
```

```bash
git clone https://github.com/shihongk/leaf.git && cd leaf && ./build.sh
```

This builds `Leaf.app` and installs it to `~/Applications`. To make it the default for Markdown files: right-click a `.md` file in Finder → Get Info → Open with → Leaf → Change All.

To update later, run `git pull && ./build.sh`.

## Math

Put `#math` on its own line (`# math` with a space works too). Everything below it (until `#endmath` or the end of the file) is calculated. A fenced code block with the language `math` works too. Nothing else in a document is ever calculated.

```
#math
rent: 1800
rent * 12 =              → 21,600
Lunch: 12 + 8 =          → 20
20% of 450 =             → 90
5 km in miles =          → 3.10686 miles
ans * 2 =                (ans = previous answer)
total =                  (sum of answers since the last blank line)
$100 in usd =            ($ always means SGD)
50 usd + 20 eur in sgd =
```

- A line ending in `=` shows its answer. Answers are display-only and never written to the file.
- Answers also update live in the editor (`Cmd+E`) as you type, shown as green pills after each line.
- `name: value` defines a variable. A label before the colon becomes a variable too (`Lunch` → `lunch`).
- Currencies use 3-letter codes (`usd`, `eur`, `jpy`, …). Rates are daily European Central Bank rates from [Frankfurter](https://frankfurter.dev), cached for offline use.
- A line that can't be worked out simply shows nothing.

## Settings

`Cmd+,`: font size, reading width, wrap code blocks, treat line breaks as breaks. `Cmd+Plus` / `Cmd+Minus` zoom.

## Development

`node tests/math.test.js` runs the math engine tests. [SPEC.md](SPEC.md) is the original design spec. Bundled libraries: markdown-it, highlight.js, math.js (each under its own licence, in `web/vendor/`).
