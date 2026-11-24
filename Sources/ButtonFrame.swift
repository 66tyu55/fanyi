import CoreGraphics
import ImageIO
import Translation
import UIKit
import Vision

struct ButtonFrame {
    struct Line {
        let text: String
        let box: CGRect
    }
    struct Result {
        let jpeg: Data
        let count: Int
        let hits: Int
    }
    enum Problem: LocalizedError {
        case image, empty, language, render
        var errorDescription: String? {
            switch self {
            case .image: return "这张画面无法读取。请重新取一张游戏画面。"
            case .empty: return "这张画面里没有识别到日文。请打开游戏菜单再试。"
            case .language: return "请打开游戏译镜，下载日语和简体中文语言包。"
            case .render: return "没能生成预览，请重试。"
            }
        }
    }
    static let japanese = Locale.Language(identifier: "ja")
    static let chinese = Locale.Language(identifier: "zh-Hans")

    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= 48 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3072
              ] as CFDictionary) else { throw Problem.image }
        return image
    }

    static func lines(_ image: CGImage, pack: GameLexicon) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.007
        request.customWords = pack.recognitionWords
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var labels = [Line]()
        for result in request.results ?? [] {
            let candidates = result.topCandidates(3)
            guard let best = candidates.first, best.confidence >= 0.3 else { continue }
            let candidate = candidates.first {
                $0.confidence + 0.12 >= best.confidence && pack.lookup($0.string) != nil
            } ?? best
            // A wide Vision line can span two separate menu buttons. Split only on a large visual gap.
            let words = candidate.string.split(whereSeparator: \.isWhitespace)
            var groups: [(String, CGRect)] = []
            if words.count > 1 {
                for word in words {
                    guard let observation = try? candidate.boundingBox(for: word.startIndex..<word.endIndex) else {
                        groups.removeAll(); break
                    }
                    let b = observation.boundingBox
                    if let last = groups.last,
                       (b.minX - last.1.maxX) * extent.width < max(12, result.boundingBox.height * extent.height * 1.4) {
                        groups[groups.count - 1] = (last.0 + " " + String(word), last.1.union(b))
                    } else { groups.append((String(word), b)) }
                }
            }
            if groups.isEmpty { groups = [(candidate.string, result.boundingBox)] }
            for (text, b) in groups {
                guard text.count <= 400, pack.lookup(text) != nil || text.unicodeScalars.contains(where: {
                    (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value) || (0xff66...0xff9f).contains($0.value)
                }) else { continue }
                let rect = CGRect(x: b.minX * extent.width, y: (1 - b.maxY) * extent.height,
                                  width: b.width * extent.width, height: b.height * extent.height).intersection(extent)
                if rect.width >= 4, rect.height >= 4 { labels.append(Line(text: text, box: rect)) }
            }
        }
        return labels
    }

    static func translate(_ source: CGImage, pack: GameLexicon) async throws -> Result {
        // Small source images need a larger recognition surface and enough pixels for Chinese strokes.
        let longSide = max(source.width, source.height)
        let image: CGImage
        if longSide < 1600 {
            let scale = min(2, 2048 / CGFloat(longSide))
            let size = CGSize(width: (CGFloat(source.width) * scale).rounded(), height: (CGFloat(source.height) * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                renderer.cgContext.interpolationQuality = .high
                UIImage(cgImage: source).draw(in: CGRect(origin: .zero, size: size))
            }.cgImage ?? source
        } else { image = source }
        var lines = try Self.lines(image, pack: pack)
        if longSide < 1600, pack.count > 0 {
            // Small icon-and-text menus sometimes merge into a single full-frame observation.
            // A cropped pass can recover a known button without guessing labels from its position.
            let field = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            for y in [CGFloat(0), 0.46] {
                let tile = CGRect(x: 0, y: y * field.height, width: field.width * 0.30,
                                  height: field.height * 0.54).integral.intersection(field)
                guard let crop = image.cropping(to: tile) else { continue }
                for item in try Self.lines(crop, pack: pack) where pack.lookup(item.text) != nil {
                    if item.box.maxX >= tile.width - 2 || (y > 0 && item.box.minY <= 2) { continue }
                    let box = item.box.offsetBy(dx: tile.minX, dy: tile.minY)
                    let candidate = Line(text: item.text, box: box)
                    if let index = lines.firstIndex(where: { line in
                        let inner = box.intersection(line.box)
                        return !inner.isNull && inner.width * inner.height >= box.width * box.height * 0.66 &&
                            line.box.width <= box.width * 2.2
                    }) {
                        if pack.lookup(lines[index].text) == nil { lines[index] = candidate }
                    } else { lines.append(candidate) }
                }
            }
        }
        guard !lines.isEmpty else { throw Problem.empty }
        var translations: [String: String] = [:]
        var unknown: [String] = []
        var seen = Set<String>()
        var hits = 0
        for line in lines {
            if let entry = pack.lookup(line.text) { translations[line.text] = entry; hits += 1 }
            else if seen.insert(line.text).inserted { unknown.append(line.text) }
        }
        if !unknown.isEmpty, await LanguageAvailability().status(from: japanese, to: chinese) == .installed {
            let session = TranslationSession(installedSource: japanese, target: chinese)
            for start in stride(from: 0, to: unknown.count, by: 24) {
                try Task.checkCancellation()
                let group = unknown[start..<min(start + 24, unknown.count)]
                let requests = group.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
                do {
                    for reply in try await session.translations(from: requests) {
                        if let key = reply.clientIdentifier, !reply.targetText.isEmpty {
                            translations[key] = reply.targetText
                        }
                    }
                } catch {
                    if translations.isEmpty { throw error }
                }
            }
        }
        try Task.checkCancellation()
        guard !translations.isEmpty else { throw Problem.language }
        let labels = lines.compactMap { line in translations[line.text].map { (line.box, $0) } }
        return Result(jpeg: try paint(image, labels), count: labels.count, hits: hits)
    }

    private static func paint(_ image: CGImage, _ labels: [(CGRect, String)]) throws -> Data {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let field = CGRect(origin: .zero, size: size)
        let output = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: image).draw(in: field)
            let canvas = context.cgContext
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            for (box, text) in labels {
                let rect = box.insetBy(dx: -min(3, box.height * 0.07), dy: -min(2, box.height * 0.04)).intersection(field)
                guard !rect.isEmpty else { continue }
                let fill = background(of: image, around: box)
                let tint: UIColor = fill.brightness > 0.49 ? .black : .white
                canvas.saveGState()
                canvas.clip(to: rect)
                canvas.setFillColor(fill.color.cgColor)
                canvas.fill(rect)
                let fit = rect.insetBy(dx: min(2, rect.width * 0.025), dy: 0)
                var pointSize = max(3, fit.height * 0.87)
                func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
                    [.font: UIFont.systemFont(ofSize: size, weight: .semibold),
                     .foregroundColor: tint, .paragraphStyle: paragraph]
                }
                let measured = (text as NSString).size(withAttributes: attributes(pointSize))
                let scale = min(1, fit.width / max(1, measured.width), fit.height / max(1, measured.height))
                pointSize *= scale
                let style = attributes(pointSize)
                let height = (text as NSString).size(withAttributes: style).height
                let textRect = CGRect(x: fit.minX, y: fit.midY - height / 2, width: fit.width, height: ceil(height) + 1)
                (text as NSString).draw(in: textRect, withAttributes: style)
                canvas.restoreGState()
            }
        }
        guard let jpeg = output.jpegData(compressionQuality: 0.93) else { throw Problem.render }
        return jpeg
    }

    // Estimate the local button fill using strips immediately around the glyphs.
    // Sampling the median avoids turning a single bright border or icon into the fill color.
    private static func background(of image: CGImage, around box: CGRect) -> (color: UIColor, brightness: CGFloat) {
        let field = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pad = max(1, box.height * 0.09)
        let strips = [CGRect(x: box.minX, y: box.minY - pad, width: box.width, height: pad),
                      CGRect(x: box.minX, y: box.maxY, width: box.width, height: pad),
                      CGRect(x: box.minX - pad, y: box.minY, width: pad, height: box.height),
                      CGRect(x: box.maxX, y: box.minY, width: pad, height: box.height)]
        var samples = [(CGFloat, CGFloat, CGFloat, CGFloat)]()
        for strip in strips {
            let rect = strip.integral.intersection(field)
            guard rect.width >= 1, rect.height >= 1, let piece = image.cropping(to: rect) else { continue }
            var bytes = [UInt8](repeating: 0, count: 32)
            bytes.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: 8, height: 1, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
                ctx.interpolationQuality = .low
                ctx.draw(piece, in: CGRect(x: 0, y: 0, width: 8, height: 1))
            }
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let r = CGFloat(bytes[i]) / 255, g = CGFloat(bytes[i+1]) / 255, b = CGFloat(bytes[i+2]) / 255
                samples.append((r, g, b, r * 0.2126 + g * 0.7152 + b * 0.0722))
            }
        }
        guard !samples.isEmpty else { return (.darkGray, 0.3) }
        samples.sort { $0.3 < $1.3 }
        let c = samples[samples.count / 2]
        return (UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1), c.3)
    }
}
