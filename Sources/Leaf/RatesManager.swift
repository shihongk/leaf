import Foundation

/// Loads ECB exchange rates from a local cache and refreshes them from Frankfurter in the
/// background when the cache is older than 24 hours. Never blocks document opening.
final class RatesManager {
    static let shared = RatesManager()
    static let updated = Notification.Name("LeafRatesUpdated")

    /// Frankfurter v2, ECB provider (base EUR). Overridable for testing via LEAF_RATES_URL.
    private let endpoint: URL = {
        if let s = ProcessInfo.processInfo.environment["LEAF_RATES_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.frankfurter.dev/v2/providers/ecb/rates")!
    }()

    private let maxAge: TimeInterval = 24 * 60 * 60
    private(set) var payload: [String: Any]? // {date, base, rates:{CODE: Double}}
    private var fetching = false

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Leaf", isDirectory: true)
        return dir.appendingPathComponent("rates.json")
    }

    func start() {
        let cached = loadCache()
        payload = cached.payload
        if cached.payload == nil || Date().timeIntervalSince(cached.fetched ?? .distantPast) > maxAge {
            refresh()
        }
        // Long-running app: check again every few hours.
        Timer.scheduledTimer(withTimeInterval: 3 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let c = self.loadCache()
            if Date().timeIntervalSince(c.fetched ?? .distantPast) > self.maxAge { self.refresh() }
        }
    }

    private func loadCache() -> (payload: [String: Any]?, fetched: Date?) {
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = obj["rates"] as? [String: Double], !rates.isEmpty,
              let date = obj["date"] as? String
        else { return (nil, nil) }
        let fetched = (obj["fetched"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return (["date": date, "base": "EUR", "rates": rates], fetched)
    }

    func refresh() {
        guard !fetching else { return }
        fetching = true
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let parsed = data.flatMap { Self.parse($0) }
            DispatchQueue.main.async {
                self.fetching = false
                guard let (date, rates) = parsed else {
                    NSLog("Leaf: rates fetch failed: \(error?.localizedDescription ?? "bad response")")
                    return
                }
                self.save(date: date, rates: rates)
                self.payload = ["date": date, "base": "EUR", "rates": rates]
                NotificationCenter.default.post(name: Self.updated, object: nil)
            }
        }.resume()
    }

    /// Accepts the v2 shape (array of {date, base, quote, rate}) and the v1 shape
    /// ({base, date, rates:{CODE: rate}}). Rates are normalised to base EUR.
    static func parse(_ data: Data) -> (String, [String: Double])? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var rates: [String: Double] = [:]
        var date = ""
        if let rows = obj as? [[String: Any]] {
            for row in rows {
                guard let base = row["base"] as? String, base.uppercased() == "EUR",
                      let quote = row["quote"] as? String,
                      let rate = (row["rate"] as? NSNumber)?.doubleValue, rate > 0 else { continue }
                rates[quote.uppercased()] = rate
                if let d = row["date"] as? String, d > date { date = d }
            }
        } else if let dict = obj as? [String: Any], let r = dict["rates"] as? [String: Any],
                  (dict["base"] as? String)?.uppercased() == "EUR" {
            for (k, v) in r { if let n = (v as? NSNumber)?.doubleValue, n > 0 { rates[k.uppercased()] = n } }
            date = dict["date"] as? String ?? ""
        }
        guard !rates.isEmpty, !date.isEmpty else { return nil }
        rates["EUR"] = 1
        return (date, rates)
    }

    private func save(date: String, rates: [String: Double]) {
        let obj: [String: Any] = ["date": date, "base": "EUR", "source": "ECB via Frankfurter",
                                  "fetched": Date().timeIntervalSince1970, "rates": rates]
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("Leaf: could not write rates cache: \(error)")
        }
    }
}
