import Foundation

/// Asks GitHub for the latest release and reports back if it's newer than the
/// running version. Best-effort: any network/parse failure just yields nil.
final class UpdateChecker {
    private let repo = "MitchelMckee/claude-traffic-light"

    /// `completion` is called (off the main thread) with the newer version +
    /// its release page, or nil if up to date / unreachable.
    func check(currentVersion: String, completion: @escaping ((version: String, url: URL)?) -> Void) {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil); return
        }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { completion(nil); return }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard UpdateChecker.isNewer(latest, than: currentVersion) else { completion(nil); return }

            let urlStr = (obj["html_url"] as? String)
                ?? "https://github.com/\(self.repo)/releases/latest"
            completion(URL(string: urlStr).map { (latest, $0) })
        }.resume()
    }

    /// Numeric dotted-version comparison: "1.10.0" > "1.9.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
