import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision

final class ScreenTextReader: NSObject, SCStreamOutput {
    let deliveryQueue = DispatchQueue(label: "gamelens.video")
    private let recognitionQueue = DispatchQueue(label: "gamelens.ocr", qos: .userInitiated)
    private let deliver: ([String]) -> Void
    private var enabled = false
    private var busy = false
    private var lastRead = -Double.infinity
    private var lastOrientation: CGImagePropertyOrientation = .up
    private var emptyFrames = 0

    init(deliver: @escaping ([String]) -> Void) { self.deliver = deliver }

    func setEnabled(_ value: Bool) {
        deliveryQueue.async { self.enabled = value }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        let now = ProcessInfo.processInfo.systemUptime
        guard type == .screen, enabled, !busy, now - lastRead >= 0.8,
              sample.isValid, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let number = info?.first?[.videoOrientation] as? NSNumber
        let hint = number.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) }
        lastRead = now
        busy = true
        recognitionQueue.async {
            let lines: [String] = autoreleasepool {
                let initial = hint ?? self.lastOrientation
                var options = [initial]
                // Some frames omit the orientation attachment after the game rotates.
                if self.emptyFrames % 5 == 1 {
                    let rotations: [CGImagePropertyOrientation] = [self.lastOrientation, .up, .left, .right, .down]
                    for choice in rotations where !options.contains(choice) { options.append(choice) }
                }
                for choice in options {
                    let result = self.recognize(image, orientation: choice)
                    if !result.isEmpty {
                        self.emptyFrames = 0
                        self.lastOrientation = choice
                        return result
                    }
                }
                // Probe alternate orientations occasionally on an empty screen.
                self.emptyFrames += 1
                return []
            }
            self.deliveryQueue.async {
                self.busy = false
                if self.enabled { self.deliver(lines) }
            }
        }
    }

    private func recognize(_ image: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cvPixelBuffer: image, orientation: orientation, options: [:]).perform([request])
        } catch { return [] }
        var found: [(row: Int, x: CGFloat, text: String)] = []
        for item in request.results ?? [] {
            guard let best = item.topCandidates(1).first, best.confidence >= 0.32 else { continue }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 600, Self.hasGameText(text) else { continue }
            found.append((Int(((1 - item.boundingBox.midY) * 100).rounded()), item.boundingBox.minX, text))
        }
        found.sort { $0.row == $1.row ? $0.x < $1.x : $0.row < $1.row }
        var seen = Set<String>()
        return found.compactMap { seen.insert($0.text).inserted ? $0.text : nil }
    }

    private static func hasGameText(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value)
                || (0xff66...0xff9f).contains($0.value)
        }
    }
}
