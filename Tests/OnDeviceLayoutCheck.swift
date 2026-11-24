import SwiftUI
import Vision

// This entry point is compiled only in the separate test IPA.
@main
struct OnDeviceLayoutCheck: App {
    var body: some Scene { WindowGroup { LayoutCheckView() } }
}

private struct Fixture: Decodable {
    struct Anchor: Decodable { let target: String; let x: Double; let y: Double }
    let name: String
    let url: URL
    let anchors: [Anchor]
}

private struct Placement: Codable {
    let label: String
    let distance: Double?
}

private struct SampleReport: Codable {
    let name: String
    var width = 0
    var height = 0
    var translated = 0
    var hits = 0
    var placements: [Placement] = []
    var error: String?
}

private struct LayoutCheckView: View {
    @State private var status = "正在独立检查按钮位置"
    @State private var started = false

    var body: some View {
        Text(status).task {
            guard !started else { return }
            started = true
            do {
                let input = ProcessInfo.processInfo.environment["GAMELENS_CHECKS"] ?? "[]"
                let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(input.utf8))
                guard !fixtures.isEmpty, fixtures.count <= 2 else { status = "等待测试输入"; return }
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                config.httpCookieStorage = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 15
                let client = URLSession(configuration: config)
                defer { client.invalidateAndCancel() }
                let pack = GameLexicon.load()
                var reports = [SampleReport]()
                for item in fixtures {
                    var report = SampleReport(name: item.name)
                    do {
                        let bytes: Data
                        if let local = ProcessInfo.processInfo.environment["GAMELENS_SAMPLE_" + item.name],
                           let supplied = Data(base64Encoded: local) {
                            bytes = supplied
                        } else {
                            guard item.url.scheme == "https" else { throw URLError(.unsupportedURL) }
                            let (data, response) = try await client.data(from: item.url)
                            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                            bytes = data
                        }
                        let source = try ButtonFrame.decode(bytes)
                        report.width = source.width
                        report.height = source.height
                        let result = try await ButtonFrame.translate(source, pack: pack)
                        report.translated = result.count
                        report.hits = result.hits
                        let image = try ButtonFrame.decode(result.jpeg)
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["zh-Hans", "en-US"]
                        request.minimumTextHeight = 0.007
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        for anchor in item.anchors {
                            let key = GameLexicon.key(anchor.target)
                            let distances = (request.results ?? []).compactMap { observation -> Double? in
                                guard let text = observation.topCandidates(1).first?.string,
                                      GameLexicon.key(text).contains(key) else { return nil }
                                let box = observation.boundingBox
                                return hypot((box.midX - anchor.x) * CGFloat(image.width),
                                             ((1 - box.midY) - anchor.y) * CGFloat(image.height))
                            }
                            report.placements.append(Placement(label: anchor.target, distance: distances.min()))
                        }
                    } catch { let e = error as NSError; report.error = "\(e.domain)(\(e.code))" }
                    reports.append(report)
                    let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("LayoutCheck.json")
                    try JSONEncoder().encode(reports).write(to: output, options: .atomic)
                }
                status = "独立检查完成"
            } catch { status = "独立检查未完成" }
        }
    }
}
