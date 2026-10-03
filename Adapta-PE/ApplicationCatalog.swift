import AppKit
import Foundation

// Comparación local: acentos/capitalización, variantes conocidas y errores breves.
struct NameMatch {
    static func key(_ text: String) -> String {
        CommandParser.normalize(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1]
            for (j, y) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))) }
            row = next
        }
        return row[b.count]
    }
    static func uniqueIndex(_ query: String, names: [[String]], allowPartial: Bool = false) -> Int? {
        let wanted = key(query)
        guard !wanted.isEmpty, wanted.count <= 160 else { return nil }
        let scores = names.enumerated().compactMap { index, variants -> (Int, Int)? in
            let score = variants.map { name -> Int in
                let candidate = key(name)
                if candidate == wanted { return 0 }
                let compact = candidate.replacingOccurrences(of: " ", with: "")
                let q = wanted.replacingOccurrences(of: " ", with: "")
                if compact == q { return 1 }
                if allowPartial, wanted.count >= 3 {
                    let words = wanted.split(separator: " ").map(String.init)
                    let candidates = candidate.split(separator: " ").map(String.init)
                    if words.allSatisfy({ candidates.contains($0) }) { return 6 }
                    if q.count >= 5, compact.contains(q) { return 7 }
                }
                guard q.count >= 4, abs(compact.count - q.count) <= 2 else { return 100 }
                let d = distance(q, compact)
                return d <= (q.count >= 8 ? 2 : 1) ? d + 2 : 100
            }.min() ?? 100
            return score < 100 ? (index, score) : nil
        }.sorted { $0.1 < $1.1 }
        guard let best = scores.first, scores.count == 1 || scores[1].1 > best.1 else { return nil }
        return best.0
    }
}

final class ApplicationCatalog {
    static let shared = ApplicationCatalog()
    private let queue = DispatchQueue(label: "pe.adapta.applications", qos: .utility)
    private var entries: [(URL, [String])] = []
    private var expires = Date.distantPast
    static let aliases = [
        "zoom": "us.zoom.xos", "zum": "us.zoom.xos", "zoom workplace": "us.zoom.xos",
        "visual studio code": "com.microsoft.VSCode", "visual estudio code": "com.microsoft.VSCode",
        "visual estudio codigo": "com.microsoft.VSCode", "vs code": "com.microsoft.VSCode", "vscode": "com.microsoft.VSCode", "code": "com.microsoft.VSCode",
        "chrome": "com.google.Chrome", "google chrome": "com.google.Chrome", "safari": "com.apple.Safari",
        "finder": "com.apple.finder", "terminal": "com.apple.Terminal", "ajustes": "com.apple.systempreferences",
        "ajustes del sistema": "com.apple.systempreferences", "calculadora": "com.apple.calculator"
    ]
    func resolve(_ name: String, completion: @escaping (URL?) -> Void) {
        queue.async {
            let key = NameMatch.key(name)
            if let id = Self.aliases[key], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                DispatchQueue.main.async { completion(url) }; return
            }
            if Date() > self.expires { self.refresh() }
            let index = NameMatch.uniqueIndex(name, names: self.entries.map { $0.1 }, allowPartial: true)
            let url = index.map { self.entries[$0].0 }
            DispatchQueue.main.async { completion(url) }
        }
    }
    private func refresh() {
        var result: [(URL, [String])] = [], seen = Set<String>()
        // ponytail: directorios de apps y tres niveles; no recorrer discos ni interiores de bundles.
        var pending = ["/Applications", "/System/Applications", "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"].map { (URL(fileURLWithPath: $0), 0) }
        while let (directory, depth) = pending.popLast() {
            let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for url in children {
                if url.pathExtension.lowercased() == "app", seen.insert(url.standardizedFileURL.path).inserted {
                    let bundle = Bundle(url: url)
                    var names = [url.deletingPathExtension().lastPathComponent]
                    for field in ["CFBundleDisplayName", "CFBundleName"] { if let name = bundle?.object(forInfoDictionaryKey: field) as? String { names.append(name) } }
                    if let id = bundle?.bundleIdentifier { names += Self.aliases.filter { $0.value == id }.map { $0.key } }
                    result.append((url, names))
                } else if depth < 2, url.pathExtension.isEmpty, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { pending.append((url, depth + 1)) }
            }
        }
        entries = result; expires = Date().addingTimeInterval(60)
    }
}
