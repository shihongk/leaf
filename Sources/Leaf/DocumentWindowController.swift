import AppKit
import WebKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    private var webView: WKWebView!
    private var editScroll: NSScrollView!
    private var textView: LeafTextView!
    private var conflictBar: NSView!
    private var findBar: NSView!
    private var findField: NSSearchField!

    private var pageLoaded = false
    private var renderPending = false
    private(set) var isEditing = false
    private var editStartScroll: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    private var doc: MarkdownDocument? { document as? MarkdownDocument }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 960),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 320, height: 240)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "LeafDocument"
        window.backgroundColor = .textBackgroundColor
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        buildViews()
        window.center()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        })
        observers.append(nc.addObserver(forName: RatesManager.updated, object: nil, queue: .main) { [weak self] _ in
            self?.render()
            self?.textView.scheduleRecompute(delay: 0)
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override var document: AnyObject? {
        didSet { if document != nil { render() } }
    }

    // MARK: View setup

    private func buildViews() {
        guard let window else { return }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // no white flash in dark mode
        webView.allowsMagnification = false
        webView.pageZoom = Settings.zoom

        (editScroll, textView) = LeafTextView.makeScrollable()
        editScroll.hasVerticalScroller = true
        editScroll.hasHorizontalScroller = false
        editScroll.drawsBackground = true
        textView.ratesProvider = { RatesManager.shared.payload }
        configureTextView()
        editScroll.isHidden = true

        conflictBar = makeConflictBar()
        conflictBar.isHidden = true
        findBar = makeFindBar()
        findBar.isHidden = true

        let content = NSView()
        for v in [webView!, editScroll!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        let stack = NSStackView(views: [conflictBar, findBar, content])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        for v in [conflictBar!, findBar!, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack

        if let web = Bundle.main.resourceURL?.appendingPathComponent("web/index.html"),
           FileManager.default.fileExists(atPath: web.path) {
            // Document images are served through LocalFileSchemeHandler, so the page only
            // needs read access to its own folder.
            webView.loadFileURL(web, allowingReadAccessTo: web.deletingLastPathComponent())
        } else {
            NSLog("Leaf: web/index.html not found in bundle resources")
        }
    }

    private func configureTextView() {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.delegate = self
        textView.onPasteIntoEmpty = { [weak self] in
            // Pasting into a blank note shows it formatted right away; Cmd+E returns to editing.
            if let self, self.isEditing { self.toggleEditMode(nil) }
        }
        // Soft wrap to the window width; never inserts line breaks into the file.
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        applyEditorFont()
    }

    private func applyEditorFont() {
        let size = CGFloat(Settings.fontSize) * 0.85 * CGFloat(Settings.zoom)
        textView.font = .monospacedSystemFont(ofSize: max(9, size), weight: .regular)
        textView.typingAttributes[.font] = textView.font
    }

    private func makeBar(_ views: [NSView]) -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    private func makeConflictBar() -> NSView {
        let label = NSTextField(labelWithString: "File changed on disk")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let reload = NSButton(title: "Reload", target: self, action: #selector(conflictReload(_:)))
        let keep = NSButton(title: "Keep mine", target: self, action: #selector(conflictKeepMine(_:)))
        for b in [reload, keep] { b.controlSize = .small; b.bezelStyle = .rounded }
        return makeBar([label, spacer, reload, keep])
    }

    private func makeFindBar() -> NSView {
        findField = NSSearchField()
        findField.placeholderString = "Find"
        findField.sendsWholeSearchString = true
        findField.target = self
        findField.action = #selector(findFieldSubmitted(_:))
        findField.delegate = self
        findField.controlSize = .small
        findField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let done = NSButton(title: "Done", target: self, action: #selector(closeFindBar(_:)))
        done.controlSize = .small
        return makeBar([spacer, findField, done])
    }

    // MARK: Rendering

    private var baseURLString: String {
        let dir = doc?.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        return dir.absoluteURL.absoluteString
    }

    /// Re-renders the reading view from the document's current text, keeping scroll position
    /// (or moving to `scrollFraction` if given).
    func render(scrollFraction: Double? = nil) {
        guard let doc else { return }
        guard pageLoaded else { renderPending = true; return }
        let payload: [String: Any] = [
            "text": doc.text,
            "baseURL": baseURLString,
            "rates": RatesManager.shared.payload ?? NSNull(),
            "settings": Settings.webPayload,
            "scrollFraction": scrollFraction ?? NSNull(),
        ]
        webView.callAsyncJavaScript("return window.leaf.render(payload);", arguments: ["payload": payload],
                                    in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { NSLog("Leaf: render failed: \(error)") }
            self?.dumpHTMLIfRequested()
        }
    }

    /// Debug hook: LEAF_DUMP_HTML=/path writes the rendered DOM after each render.
    private func dumpHTMLIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LEAF_DUMP_HTML"], !path.isEmpty else { return }
        let name = doc?.fileURL?.deletingPathExtension().lastPathComponent ?? "untitled"
        let target = path.replacingOccurrences(of: "%n", with: name)
        let js = """
        JSON.stringify({scrollY: window.scrollY, innerWidth: window.innerWidth,
          pageScrollWidth: document.documentElement.scrollWidth,
          pres: [...document.querySelectorAll('pre')].map(e => [e.scrollWidth, e.clientWidth]),
          tables: [...document.querySelectorAll('.table-wrap')].map(e => [e.scrollWidth, e.clientWidth]),
          images: [...document.querySelectorAll('img')].map(e => [e.src, e.complete, e.naturalWidth]),
          html: document.documentElement.outerHTML})
        """
        webView.evaluateJavaScript(js) { value, _ in
            guard let s = value as? String else { return }
            try? s.write(toFile: target, atomically: true, encoding: .utf8)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if renderPending || doc != nil { renderPending = false; render() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoaded = false
        webView.reload()
    }

    // Never navigate the web view: links open in the default browser / app.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let isIndex = url.isFileURL && url.path.hasSuffix("/web/index.html")
            && url.path.hasPrefix(Bundle.main.resourceURL?.path ?? "/nonexistent")
        if isIndex && navigationAction.navigationType != .linkActivated && navigationAction.targetFrame?.isMainFrame == true {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated { openExternally(url) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "file"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Document callbacks

    /// The document's text was replaced (initial load or reload from disk).
    func documentTextReplaced() {
        if isEditing {
            let visible = textView.visibleRect
            textView.string = doc?.text ?? ""
            textView.scroll(visible.origin)
        }
        render()
    }

    func syncTextFromEditor() {
        if isEditing { doc?.text = textView.string }
    }

    func textDidChange(_ notification: Notification) {
        doc?.text = textView.string
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        doc?.undoManager
    }

    func showConflictBar() { conflictBar.isHidden = false }
    func hideConflictBar() { conflictBar.isHidden = true }

    @objc private func conflictReload(_ sender: Any?) { doc?.reloadFromDisk() }
    @objc private func conflictKeepMine(_ sender: Any?) { doc?.keepMine() }

    // MARK: Edit toggle

    private var editScrollFraction: CGFloat {
        let docHeight = textView.frame.height - editScroll.contentView.bounds.height
        guard docHeight > 0 else { return 0 }
        return min(1, max(0, editScroll.contentView.bounds.origin.y / docHeight))
    }

    private func setEditScrollFraction(_ f: CGFloat) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let docHeight = textView.frame.height - editScroll.contentView.bounds.height
        let y = max(0, docHeight * f)
        editScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        editScroll.reflectScrolledClipView(editScroll.contentView)
    }

    @objc func toggleEditMode(_ sender: Any?) {
        guard let doc else { return }
        if isEditing {
            doc.text = textView.string
            let scrolledInEditor = abs(editScroll.contentView.bounds.origin.y - editStartScroll) > 2
            let fraction = scrolledInEditor ? Double(editScrollFraction) : nil
            isEditing = false
            editScroll.isHidden = true
            webView.isHidden = false
            window?.makeFirstResponder(webView)
            render(scrollFraction: fraction)
        } else {
            if textView.string != doc.text { textView.string = doc.text }
            isEditing = true
            webView.evaluateJavaScript("window.leaf ? window.leaf.scrollFraction() : 0") { [weak self] value, _ in
                guard let self else { return }
                let f = (value as? Double) ?? 0
                self.webView.isHidden = true
                self.editScroll.isHidden = false
                self.setEditScrollFraction(CGFloat(f))
                self.editStartScroll = self.editScroll.contentView.bounds.origin.y
                self.window?.makeFirstResponder(self.textView)
            }
        }
    }

    // MARK: Zoom and settings

    @objc func zoomIn(_ sender: Any?) { Settings.zoom = (Settings.zoom * 1.1 * 100).rounded() / 100 }
    @objc func zoomOut(_ sender: Any?) { Settings.zoom = (Settings.zoom / 1.1 * 100).rounded() / 100 }
    @objc func zoomActualSize(_ sender: Any?) { Settings.zoom = 1.0 }

    private func applySettings() {
        webView.pageZoom = Settings.zoom
        applyEditorFont()
        render()
    }

    // MARK: Find

    @objc func leafFind(_ sender: Any?) {
        if isEditing { textFinder(.showFindInterface); return }
        findBar.isHidden = false
        window?.makeFirstResponder(findField)
    }

    @objc func leafFindNext(_ sender: Any?) {
        if isEditing { textFinder(.nextMatch); return }
        findInPage(backwards: false)
    }

    @objc func leafFindPrevious(_ sender: Any?) {
        if isEditing { textFinder(.previousMatch); return }
        findInPage(backwards: true)
    }

    private func textFinder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    @objc private func findFieldSubmitted(_ sender: Any?) { findInPage(backwards: false) }

    @objc private func closeFindBar(_ sender: Any?) {
        findBar.isHidden = true
        window?.makeFirstResponder(webView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === findField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeFindBar(nil)
            return true
        }
        return false
    }

    private func findInPage(backwards: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else { leafFind(nil); return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.caseSensitive = false
        cfg.wraps = true
        webView.find(query, configuration: cfg) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }

    // MARK: Debug (LEAF_DEBUG=1 only)

    func debugPaste() {
        guard isEditing else { return }
        window?.makeFirstResponder(textView)
        textView.paste(nil)
    }

    func debugInsert(_ text: String) {
        guard isEditing else { return }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(text, replacementRange: textView.selectedRange())
        doc?.undoManager?.endUndoGrouping() // close the typing group like the run loop would
        doc?.undoManager?.beginUndoGrouping()
    }

    func debugState() -> [String: Any] {
        [
            "editing": isEditing,
            "dirty": doc?.isDocumentEdited ?? false,
            "conflictVisible": !conflictBar.isHidden,
            "textLength": (doc?.text as NSString?)?.length ?? 0,
            "editorTextLength": (textView.string as NSString).length,
            "zoom": Double(webView.pageZoom),
            "editorScrollY": Double(editScroll.contentView.bounds.origin.y),
            // Live editor answers, keyed by 1-based line number.
            "liveAnswers": Dictionary(uniqueKeysWithValues: textView.liveAnswers.map { (String($0.key + 1), $0.value.text) }),
            // 1-based lines whose answer has the auto-shown ghost "=".
            "implicitEqLines": textView.liveAnswers.filter { $0.value.implicitEq }.keys.map { $0 + 1 }.sorted(),
            // 1-based marker lines (#math / end marker) and those actually carrying the accent.
            "markerLines": textView.markerLines.map { $0 + 1 }.sorted(),
            "accentedLines": textView.accentedLines.map { $0 + 1 },
        ]
    }
}
