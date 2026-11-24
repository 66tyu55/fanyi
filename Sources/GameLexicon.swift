import Foundation

struct GameLexicon {
    private var words: [String: String] = [:]
    var count: Int { words.count }
    var recognitionWords: [String] { Array(words.keys.filter { $0.count <= 24 }.sorted().prefix(512)) }
    var error: String?
    private(set) var gameURL: URL?
    private(set) var buttonRegions: [ButtonRegion] = []

    struct Entry: Codable {
        let ja: String
        let zhHans: String
    }
    struct Anchor: Codable { let ja: String; let x: Double; let y: Double }
    struct ButtonRegion: Codable {
        let ja: String
        let variants: [String]
        let anchors: [Anchor]
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    struct Pack: Codable {
        let version: Int
        var gameURLScheme: String?
        var buttonRegions: [ButtonRegion]?
        let entries: [Entry]
    }

    static func key(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    func lookup(_ text: String) -> String? {
        let key = Self.key(text)
        if let exact = words[key] { return exact }
        let ornaments = CharacterSet(charactersIn: "〈〉《》‹›※◆◇●○◯■□▶◀←→×•")
        return words[key.trimmingCharacters(in: ornaments)]
    }

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
            result.buttonRegions = (pack.buttonRegions ?? []).prefix(24).filter { region in
                result.lookup(region.ja) != nil && (2...8).contains(region.anchors.count) &&
                region.width > 0 && region.height > 0 && region.x >= 0 && region.y >= 0 &&
                region.x + region.width <= 1 && region.y + region.height <= 1
            }
        } catch {
            result.error = "个人词库未能读取。"
        }
        return result
    }
}
