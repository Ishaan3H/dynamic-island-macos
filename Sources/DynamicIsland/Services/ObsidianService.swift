import AppKit
import Foundation

struct ObsidianVault: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
}

/// Opens Obsidian vaults by spoken name.
///
/// Obsidian keeps its vault registry in `obsidian.json`, so the list of real vault
/// names is available without asking the user to configure anything — which
/// matters, because matching a *dictated* name against a known set is far more
/// forgiving than trusting the transcript verbatim. "open vault I P M" has to
/// reach the vault called `IPM`.
final class ObsidianService {

    private static var registryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "obsidian://open")!
        ) != nil
    }

    func vaults() -> [ObsidianVault] {
        guard let data = try? Data(contentsOf: Self.registryURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["vaults"] as? [String: [String: Any]]
        else { return [] }

        return entries.values
            .compactMap { entry -> ObsidianVault? in
                guard let path = entry["path"] as? String else { return nil }
                return ObsidianVault(name: (path as NSString).lastPathComponent, path: path)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Best match for a dictated name, or `nil` if nothing is close enough.
    func match(_ query: String) -> ObsidianVault? {
        let candidates = vaults()
        guard !candidates.isEmpty else { return nil }

        let needle = Self.normalise(query)
        guard !needle.isEmpty else { return nil }

        var best: (vault: ObsidianVault, score: Double)?
        for vault in candidates {
            let score = Self.score(needle: needle, against: Self.normalise(vault.name))
            if score > (best?.score ?? 0) { best = (vault, score) }
        }

        guard let best, best.score >= 0.55 else { return nil }
        return best.vault
    }

    @discardableResult
    func open(_ vault: ObsidianVault) -> Bool {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "vault", value: vault.name)]
        guard let url = components.url else { return false }
        Log.debug("obsidian: opening \(vault.name)")
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Matching

    /// Strips everything that dictation is unreliable about: case, spacing, and
    /// punctuation. "I.P.M." and "i p m" both collapse to "ipm".
    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func score(needle: String, against name: String) -> Double {
        guard !name.isEmpty else { return 0 }
        if needle == name { return 1.0 }
        if name.hasPrefix(needle) || needle.hasPrefix(name) { return 0.9 }
        if name.contains(needle) || needle.contains(name) { return 0.8 }

        // Fall back to normalised edit distance, so one dictation slip still hits.
        let distance = levenshtein(needle, name)
        let longest = max(needle.count, name.count)
        return 1.0 - (Double(distance) / Double(longest))
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[y.count]
    }
}
