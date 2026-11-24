import AVKit
import CoreText
import SwiftUI

struct CaptionPreview: UIViewRepresentable {
    let captions: Captions
    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.layer.addSublayer(captions.layer)
        return view
    }
    func updateUIView(_ view: PreviewLayerView, context: Context) { view.setNeedsLayout() }
}

final class PreviewLayerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.first?.frame = bounds
    }
}

@MainActor
final class Captions: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let layer = AVSampleBufferDisplayLayer()
    var onDismiss: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var controller: AVPictureInPictureController?
    private var ticker: Task<Void, Never>?
    private var wantsWindow = false
    private var startIssued = false
    private var beganAt: TimeInterval = 0
    private var pageSince: TimeInterval = 0
    private var page = 0
    private var pages: [String] = []
    private var previous: [String] = []
    private let size = CGSize(width: 882, height: 360)
    private let inset: CGFloat = 18
    private let placeholder = "等待游戏文字"
    private let font = UIFont.systemFont(ofSize: 42, weight: .medium)

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        render()
    }

    func start() throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw NSError(domain: "GameLens", code: 1, userInfo: [NSLocalizedDescriptionKey: "这台设备当前无法使用画中画。"])
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audio.setActive(true)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.requiresLinearPlayback = true
        controller = pip
        wantsWindow = true
        startIssued = false
        beganAt = ProcessInfo.processInfo.systemUptime
        pageSince = beganAt
        render()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stop() {
        wantsWindow = false
        ticker?.cancel()
        ticker = nil
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
        previous = []
        pages = []
        page = 0
        layer.sampleBufferRenderer.flush()
        render()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func show(_ lines: [String]) {
        guard lines != previous else { return }
        previous = lines
        pages = split(lines.joined(separator: "\n"))
        page = 0
        pageSince = ProcessInfo.processInfo.systemUptime
        render()
    }

    private func tick() {
        guard wantsWindow, let pip = controller else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !pip.isPictureInPictureActive {
            if !startIssued && pip.isPictureInPicturePossible {
                startIssued = true
                pip.startPictureInPicture()
            } else if now - beganAt > 12 {
                onFailure?("字幕窗口未能打开。请在系统设置中允许画中画，再点开始。")
                return
            }
        }
        if pages.count > 1, now - pageSince >= 4.5 {
            page = (page + 1) % pages.count
            pageSince = now
        }
        render()
    }

    private func styled(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 3
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph
        ])
    }

    private func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let value = text as NSString
        let framesetter = CTFramesetterCreateWithAttributedString(styled(text))
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset + 3)
        let path = CGPath(rect: bounds, transform: nil)
        var result: [String] = []
        var offset = 0
        while offset < value.length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let count = CTFrameGetVisibleStringRange(frame).length
            guard count > 0 else { break }
            result.append(value.substring(with: NSRange(location: offset, length: count)))
            offset += count
        }
        return result
    }

    private func render() {
        var pixel: CVPixelBuffer?
        let options = [kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary] as CFDictionary
        let w = Int(size.width), h = Int(size.height)
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, options, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            let bounds = CGRect(origin: .zero, size: size)
            ctx.setFillColor(UIColor(white: 0.07, alpha: 1).cgColor)
            ctx.fill(bounds)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            let text = pages.indices.contains(page) ? pages[page] : placeholder
            styled(text).draw(with: bounds.insetBy(dx: inset, dy: inset),
                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2),
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        if wantsWindow { onFailure?(error.localizedDescription) }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        if wantsWindow { onDismiss?() }
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime,
                                    completionHandler: @escaping () -> Void) { completionHandler() }
}
