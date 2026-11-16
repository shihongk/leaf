import AppKit
import SwiftUI

/// User preferences, stored in UserDefaults. Windows observe `Settings.changed`.
enum Settings {
    static let changed = Notification.Name("LeafSettingsChanged")

    enum Key {
        static let zoom = "zoom"
        static let fontSize = "fontSize"
        static let readingWidth = "readingWidth"
        static let wrapCode = "wrapCodeBlocks"
        static let breaks = "lineBreaksAsBreaks"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.zoom: 1.0,
            Key.fontSize: 16,
            Key.readingWidth: "medium",
            Key.wrapCode: false,
            Key.breaks: false,
        ])
    }

    static var zoom: Double {
        get { UserDefaults.standard.double(forKey: Key.zoom) }
        set { UserDefaults.standard.set(min(3.0, max(0.5, newValue)), forKey: Key.zoom); notify() }
    }
    static var fontSize: Int { UserDefaults.standard.integer(forKey: Key.fontSize) }
    static var readingWidth: String { UserDefaults.standard.string(forKey: Key.readingWidth) ?? "medium" }
    static var wrapCode: Bool { UserDefaults.standard.bool(forKey: Key.wrapCode) }
    static var breaks: Bool { UserDefaults.standard.bool(forKey: Key.breaks) }

    static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Settings passed to the web view's render function.
    static var webPayload: [String: Any] {
        [
            "fontSize": fontSize,
            "readingWidth": readingWidth,
            "wrapCode": wrapCode,
            "breaks": breaks,
        ]
    }
}

struct SettingsView: View {
    @AppStorage(Settings.Key.fontSize) private var fontSize = 16
    @AppStorage(Settings.Key.readingWidth) private var readingWidth = "medium"
    @AppStorage(Settings.Key.wrapCode) private var wrapCode = false
    @AppStorage(Settings.Key.breaks) private var breaks = false

    var body: some View {
        Form {
            Stepper(value: $fontSize, in: 11...28) {
                Text("Font size: \(fontSize) pt")
            }
            Picker("Reading width", selection: $readingWidth) {
                Text("Narrow").tag("narrow")
                Text("Medium").tag("medium")
                Text("Wide").tag("wide")
            }
            .pickerStyle(.segmented)
            Toggle("Wrap code blocks", isOn: $wrapCode)
            Toggle("Treat line breaks as breaks", isOn: $breaks)
        }
        .padding(20)
        .frame(width: 380)
        .onChange(of: fontSize) { Settings.notify() }
        .onChange(of: readingWidth) { Settings.notify() }
        .onChange(of: wrapCode) { Settings.notify() }
        .onChange(of: breaks) { Settings.notify() }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "Leaf Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
