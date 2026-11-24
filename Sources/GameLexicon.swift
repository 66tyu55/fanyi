import Foundation

struct GameLexicon {
    private var words: [String: String] = [:]
    var count: Int { words.count }
    var error: String?
    private(set) var gameURL: URL?

    struct Entry: Codable {
        let ja: String
        let zhHans: String
    }
    struct Pack: Codable {
        let version: Int
        var gameURLScheme: String?
        let entries: [Entry]
    }

    static func key(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    func lookup(_ text: String) -> String? { words[Self.key(text)] }

    static func load() -> GameLexicon {
        let files = FileManager.default
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let personal = documents.appendingPathComponent("GameLexicon.json")
        var result = GameLexicon()
        guard files.fileExists(atPath: personal.path) else { return result }
        do {
            let attributes = try files.attributesOfItem(atPath: personal.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value <= 96 * 1024 * 1024 else {
                result.error = "个人词库超过 96 MB。"
                return result
            }
            let pack = try JSONDecoder().decode(Pack.self, from: Data(contentsOf: personal, options: .mappedIfSafe))
            guard pack.version == 1 else { result.error = "个人词库格式版本不兼容。"; return result }
            if let scheme = pack.gameURLScheme, scheme.contains("."),
               scheme.range(of: "^[a-z][a-z0-9.-]{2,79}$", options: .regularExpression) != nil {
                result.gameURL = URL(string: scheme + "://")
            }
            var ambiguous = Set<String>()
            for row in pack.entries {
                let key = Self.key(row.ja)
                let value = row.zhHans.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty, !ambiguous.contains(key) else { continue }
                if let prior = result.words[key], prior != value {
                    result.words.removeValue(forKey: key)
                    ambiguous.insert(key)
                } else {
                    result.words[key] = value
                }
            }
        } catch {
            result.error = "个人词库未能读取。"
        }
        return result
    }
}
