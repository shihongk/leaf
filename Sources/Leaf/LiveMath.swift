import AppKit
import JavaScriptCore

/// Computes math answers for the editor with the same JavaScript engine the reading view uses
/// (bundled math.js + leafmath.js), in a JavaScriptCore context on a private serial queue.
struct LiveAnswer: Equatable {
    var text: String
    /// The typed line has no trailing "=": the editor draws a ghost "=" before the pill.
    var implicitEq: Bool
}

struct LiveMathResult {
    var answers: [Int: LiveAnswer] = [:]
    /// 0-based lines of the real #math / end-marker lines (as decided by the JS engine).
    var markers: [Int] = []
}

final class LiveMathEngine {
    static let shared = LiveMathEngine()

    private let queue = DispatchQueue(label: "local.leaf.livemath", qos: .userInitiated)
    private var context: JSContext? // only touched on `queue`
    private var loadFailed = false

    /// Answers keyed by 0-based source line (text split on "\n"). Calls back on the main queue.
    func answers(for text: String, rates: [String: Any]?, completion: @escaping (LiveMathResult) -> Void) {
        let ratesJSON: String = {
            guard let rates, let data = try? JSONSerialization.data(withJSONObject: rates) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }()
        queue.async { [self] in
            let result = compute(text: text, ratesJSON: ratesJSON)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func compute(text: String, ratesJSON: String) -> LiveMathResult {
        guard let ctx = loadContext(), let fn = ctx.objectForKeyedSubscript("leafLiveAnswers") else { return LiveMathResult() }
        guard let value = fn.call(withArguments: [text, ratesJSON]), let json = value.toString(),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return LiveMathResult() }
        var out = LiveMathResult()
        for case let row as [Any] in (obj["answers"] as? [Any]) ?? [] where row.count == 3 {
            if let line = (row[0] as? NSNumber)?.intValue, let answer = row[1] as? String {
                out.answers[line] = LiveAnswer(text: answer, implicitEq: (row[2] as? NSNumber)?.boolValue ?? false)
            }
        }
        out.markers = ((obj["markers"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        return out
    }

    private func loadContext() -> JSContext? {
        if let context { return context }
        if loadFailed { return nil }
        guard let web = Bundle.main.resourceURL?.appendingPathComponent("web"),
              let mathJS = try? String(contentsOf: web.appendingPathComponent("vendor/math.min.js"), encoding: .utf8),
              let leafJS = try? String(contentsOf: web.appendingPathComponent("leafmath.js"), encoding: .utf8),
              let ctx = JSContext()
        else {
            NSLog("Leaf: live math unavailable (web resources not found)")
            loadFailed = true
            return nil
        }
        var failed = false
        ctx.exceptionHandler = { _, exc in
            NSLog("Leaf: live math JS error: \(exc?.toString() ?? "?")")
            failed = true
        }
        ctx.evaluateScript(mathJS, withSourceURL: web.appendingPathComponent("vendor/math.min.js"))
        ctx.evaluateScript(leafJS, withSourceURL: web.appendingPathComponent("leafmath.js"))
        // Engine is cached per rates payload, like the reading view's getEngine().
        ctx.evaluateScript("""
        var leafLiveAnswers = (function () {
          var engine = null, key = null;
          return function (text, ratesJSON) {
            if (!engine || key !== ratesJSON) {
              engine = LeafMath.createEngine(math, JSON.parse(ratesJSON));
              key = ratesJSON;
            }
            return JSON.stringify({
              answers: LeafMath.documentAnswers(engine, text).map(function (a) { return [a.line, a.answer, !!a.implicitEq]; }),
              markers: LeafMath.documentMarkers(text)
            });
          };
        })();
        """)
        if failed || ctx.objectForKeyedSubscript("LeafMath")?.isUndefined != false {
            loadFailed = true
            return nil
        }
        ctx.exceptionHandler = { _, exc in NSLog("Leaf: live math JS error: \(exc?.toString() ?? "?")") }
        context = ctx
        return ctx
    }
}

/// The editor: a plain-text NSTextView (TextKit 1) that draws live math answers as ghost pills
/// after the end of their lines. Answers are drawn only; they are never in the text storage,
/// so they can't be saved, copied, selected or undone.
final class LeafTextView: NSTextView, NSTextStorageDelegate {
    /// Current answers by 0-based source line.
    private(set) var liveAnswers: [Int: LiveAnswer] = [:]
    /// 0-based marker lines (#math / end marker) currently accented.
    private(set) var markerLines: [Int] = []
    /// Rates passed to the math engine (same payload the reading view gets).
    var ratesProvider: () -> [String: Any]? = { nil }

    /// Called after pasting into a completely empty note, so the window can show it formatted.
    var onPasteIntoEmpty: (() -> Void)?

    override func paste(_ sender: Any?) {
        let wasEmpty = string.isEmpty
        super.paste(sender)
        if wasEmpty && !string.isEmpty { DispatchQueue.main.async { [weak self] in self?.onPasteIntoEmpty?() } }
    }

    private var debounce: DispatchWorkItem?
    private var generation = 0
    private var lineCount = 1
    private var lineStartsCache: [Int]?

    static func makeScrollable() -> (NSScrollView, LeafTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        // Size the text view to the clip view so width autoresizing keeps them equal (soft wrap).
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.hasVerticalScroller = true
        let tv = LeafTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        storage.delegate = tv
        scroll.documentView = tv
        return (scroll, tv)
    }

    // MARK: Recompute

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        lineStartsCache = nil
        let s = textStorage.string as NSString
        let newCount = Self.lineStarts(of: s).count
        let lineDelta = newCount - lineCount
        lineCount = newCount
        if lineDelta != 0 && !liveAnswers.isEmpty {
            // Keep existing pills on their lines until the fresh answers arrive.
            let startLine = Self.lineIndex(of: editedRange.location, in: lineStarts())
            var shifted: [Int: LiveAnswer] = [:]
            for (line, answer) in liveAnswers {
                if line < startLine { shifted[line] = answer }
                else if line == startLine { continue }
                else if lineDelta < 0 && line <= startLine - lineDelta { continue }
                else { shifted[line + lineDelta] = answer }
            }
            liveAnswers = shifted
            needsDisplay = true
        }
        scheduleRecompute()
    }

    func scheduleRecompute(delay: TimeInterval = 0.1) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeNow() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recomputeNow() {
        generation += 1
        let gen = generation
        let text = string
        LiveMathEngine.shared.answers(for: text, rates: ratesProvider()) { [weak self] result in
            guard let self, gen == self.generation, text == self.string else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: LiveMathResult) {
        let answers = result.answers
        if answers != liveAnswers {
            let changed = Set(answers.keys).union(liveAnswers.keys).filter { answers[$0] != liveAnswers[$0] }
            let old = changed.compactMap { invalidationRect(line: $0, answer: liveAnswers[$0]) }
            liveAnswers = answers
            let new = changed.compactMap { invalidationRect(line: $0, answer: answers[$0]) }
            for r in old + new { setNeedsDisplay(r.insetBy(dx: -2, dy: -2)) }
        }
        markerLines = result.markers
        applyMarkerAccent()
    }

    // MARK: Marker accent

    private static let markerColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x56 / 255, green: 0xc8 / 255, blue: 0x73 / 255, alpha: 1)
            : NSColor(srgbRed: 0x1f / 255, green: 0x7a / 255, blue: 0x37 / 255, alpha: 1)
    }

    /// Colours the #math / end-marker lines with layout-manager temporary attributes only: the
    /// text storage (saved content, undo stack) is never touched.
    private func applyMarkerAccent() {
        guard let lm = layoutManager else { return }
        let s = string as NSString
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
        let starts = lineStarts()
        for line in markerLines where line >= 0 && line < starts.count {
            let start = starts[line]
            var end = line + 1 < starts.count ? starts[line + 1] - 1 : s.length
            if end > start, s.character(at: end - 1) == 13 { end -= 1 }
            guard end > start else { continue }
            lm.addTemporaryAttribute(.foregroundColor, value: Self.markerColor,
                                     forCharacterRange: NSRange(location: start, length: end - start))
        }
        needsDisplay = true
    }

    /// 0-based lines whose text currently carries the marker accent (for the debug state).
    var accentedLines: [Int] {
        guard let lm = layoutManager else { return [] }
        let starts = lineStarts()
        return markerLines.filter { line in
            line >= 0 && line < starts.count && starts[line] < (string as NSString).length
                && lm.temporaryAttribute(.foregroundColor, atCharacterIndex: starts[line], effectiveRange: nil) != nil
        }.sorted()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMarkerAccent()
    }

    // MARK: Geometry

    private static func lineStarts(of s: NSString) -> [Int] {
        var starts = [0]
        var loc = 0
        let len = s.length
        while loc < len {
            let r = s.range(of: "\n", options: .literal, range: NSRange(location: loc, length: len - loc))
            if r.location == NSNotFound { break }
            loc = r.location + 1
            starts.append(loc)
        }
        return starts
    }

    private func lineStarts() -> [Int] {
        if let c = lineStartsCache { return c }
        let c = Self.lineStarts(of: string as NSString)
        lineStartsCache = c
        return c
    }

    private static func lineIndex(of location: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private var pillFont: NSFont {
        let size = (font?.pointSize ?? 12) * 0.92
        return .monospacedSystemFont(ofSize: size, weight: .medium)
    }

    private static let pillFG = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x7d / 255, green: 0xdc / 255, blue: 0x95 / 255, alpha: 1)
            : NSColor(srgbRed: 0x1a / 255, green: 0x6b / 255, blue: 0x30 / 255, alpha: 1)
    }
    private static let pillBG = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3f / 255, green: 0xb6 / 255, blue: 0x5c / 255, alpha: 0.16)
            : NSColor(srgbRed: 0x29 / 255, green: 0x99 / 255, blue: 0x45 / 255, alpha: 0.12)
    }
    private static let pillBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3f / 255, green: 0xb6 / 255, blue: 0x5c / 255, alpha: 0.4)
            : NSColor(srgbRed: 0x29 / 255, green: 0x99 / 255, blue: 0x45 / 255, alpha: 0.33)
    }

    private func pillAttributes() -> [NSAttributedString.Key: Any] {
        [.font: pillFont, .foregroundColor: Self.pillFG]
    }

    /// Where the pill for `line` goes: just after the last visual fragment of that line.
    private var eqAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
         .foregroundColor: NSColor.secondaryLabelColor]
    }
    private var eqWidth: CGFloat { ceil((" =" as NSString).size(withAttributes: eqAttributes).width) }

    /// Area to redraw for a line's ghost "=" plus pill.
    private func invalidationRect(line: Int, answer: LiveAnswer?) -> NSRect? {
        guard let answer, let r = pillRect(line: line, answer: answer) else { return nil }
        return answer.implicitEq ? r.insetBy(dx: -(eqWidth + 8), dy: 0).offsetBy(dx: -(eqWidth + 8) / 2, dy: 0) : r
    }

    private func pillRect(line: Int, answer liveAnswer: LiveAnswer?) -> NSRect? {
        guard let liveAnswer, let lm = layoutManager else { return nil }
        let answer = liveAnswer.text
        let starts = lineStarts()
        guard line >= 0, line < starts.count else { return nil }
        let s = string as NSString
        let start = starts[line]
        var end = line + 1 < starts.count ? starts[line + 1] - 1 : s.length // exclude "\n"
        if end > start, s.character(at: end - 1) == 13 { end -= 1 } // and "\r"
        guard end > start else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: end - 1)
        guard glyph < lm.numberOfGlyphs else { return nil }
        var used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textContainerOrigin
        used.origin.x += origin.x
        used.origin.y += origin.y
        let size = (answer as NSString).size(withAttributes: pillAttributes())
        let padX: CGFloat = 6
        let h = ceil(size.height) + 2
        let gap: CGFloat = 8
        let midY = frag.midY + origin.y
        let eqShift = liveAnswer.implicitEq ? eqWidth : 0
        return NSRect(x: ceil(used.maxX + gap + eqShift), y: floor(midY - h / 2),
                      width: ceil(size.width) + padX * 2, height: h)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !liveAnswers.isEmpty else { return }
        let attrs = pillAttributes()
        NSGraphicsContext.saveGraphicsState()
        for (line, answer) in liveAnswers {
            guard let r = pillRect(line: line, answer: answer),
                  r.insetBy(dx: answer.implicitEq ? -(eqWidth + 8) : 0, dy: 0).intersects(dirtyRect) else { continue }
            if answer.implicitEq {
                // Ghost "=": drawn only, in the text font and secondary colour; never in the text storage.
                let eq = " =" as NSString
                let esize = eq.size(withAttributes: eqAttributes)
                eq.draw(at: NSPoint(x: r.minX - 8 - eqWidth, y: r.midY - esize.height / 2), withAttributes: eqAttributes)
            }
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            Self.pillBG.setFill()
            path.fill()
            Self.pillBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            let size = (answer.text as NSString).size(withAttributes: attrs)
            (answer.text as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.midY - size.height / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The text view invalidates only the edited text; also redraw the full width of every
    /// fragment of the edited line so its pill (which sits beyond the text) moves with it.
    override func didChangeText() {
        super.didChangeText()
        guard let lm = layoutManager else { return }
        let s = string as NSString
        let starts = lineStarts()
        let line = Self.lineIndex(of: min(selectedRange().location, s.length), in: starts)
        let end = line + 1 < starts.count ? starts[line + 1] : s.length
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: starts[line], length: end - starts[line]),
                                   actualCharacterRange: nil)
        guard let tc = textContainer, glyphs.length > 0 else { return }
        var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        r.origin.y += textContainerOrigin.y
        setNeedsDisplay(NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height))
    }
}
