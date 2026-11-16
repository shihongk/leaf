# Leaf formatting demo

A paragraph with **bold**, *italic*, ~~strikethrough~~, `inline code` and a [link to example.com](https://example.com).
Autolinked URL: https://www.apple.com and an [in-page link](#tables).

## Lists

- First item
- Second item with a nested list
  - Nested one
  - Nested two
1. Numbered
2. List

### Task list

- [x] Write the spec
- [ ] Build Leaf
- [ ] Ship it

## Quote

> Markdown is a lightweight markup language.
> -- John Gruber

## Code

```swift
struct Leaf {
    let name = "Leaf"
    func greet() -> String { "Hello, \(name)!" }
}
```

```js
const answer = [1, 2, 3].map(x => x * 2);
```

200-character code line:

```
let veryLongVariableName = computeSomethingExpensive(alpha, beta, gamma, delta) + anotherFunctionCall(epsilon, zeta, eta, theta) + yetAnotherOne(iota, kappa, lambda) // end xxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## Tables

| Name | Qty | Price |
|:-----|----:|------:|
| Apple | 3 | 1.20 |
| Pear | 10 | 0.80 |

Twelve columns:

| Column 1 | Column 2 | Column 3 | Column 4 | Column 5 | Column 6 | Column 7 | Column 8 | Column 9 | Column 10 | Column 11 | Column 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| value 1 wide cell | value 2 wide cell | value 3 wide cell | value 4 wide cell | value 5 wide cell | value 6 wide cell | value 7 wide cell | value 8 wide cell | value 9 wide cell | value 10 wide cell | value 11 wide cell | value 12 wide cell |

## Image (relative path)

![Green gradient](images/green.png)

## Long line

This is a deliberately long line of body text that keeps going without any manual line breaks so that we can check wrapping in the reading view. This is a deliberately long line of body text that keeps going without any manual line breaks so that we can check wrapping in the reading view. This is a 

A long URL: https://example.com/a/very/long/path/that/should/wrap/anywhere/because/it/has/no/spaces/at/all/and/keeps/going/and/going/and/going

## Raw HTML must not render

<script>alert(1)</script>

<b>this should appear as literal tags</b>

## Not a math region

Cost: 5 + 5 =

---

The end.
