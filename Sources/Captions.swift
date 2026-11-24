import AVKit
import CoreText
import SwiftUI

struct CaptionPreview: UIViewRepresentable {
    let captions: Captions
    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        captions.attach(view)
        return view
    }
    func updateUIView(_ view: PreviewLayerView, context: Context) {}
}

final class PreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

@MainActor
final class Captions: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private weak var preview: PreviewLayerView?
    private var layer: AVSampleBufferDisplayLayer? { preview?.videoLayer }
    private var timebase: CMTimebase?
    var onDismiss: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onOpened: (() -> Void)?
    var onReady: ((Bool) -> Void)?
    var trace: ((String) -> Void)?
    private var controller: AVPictureInPictureController?
    private var ticker: Task<Void, Never>?
    private var wantsWindow = false
    private var startIssued = false
    private var issuedAt: TimeInterval = 0
    private var ready = false
    private var audioActive = false
    private var pageSince: TimeInterval = 0
    private var page = 0
    private var pages: [String] = []
    private var previous: [String] = []
    private let size = CGSize(width: 882, height: 360)
    private let inset: CGFloat = 18
    private let placeholder = "等待游戏文字"
    private let font = UIFont.systemFont(ofSize: 42, weight: .medium)

    func attach(_ view: PreviewLayerView) {
        guard preview !== view else { return }
        preview = view
        let layer = view.videoLayer
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        var clock: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr,
           let clock {
            CMTimebaseSetTime(clock, time: .zero)
            CMTimebaseSetRate(clock, rate: 1)
            layer.controlTimebase = clock
            timebase = clock
        }
        render()
        prepareController()
    }

    private func prepareController() {
        guard let layer, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.requiresLinearPlayback = true
        controller = pip
    }

    func start() {
        wantsWindow = true
        startIssued = false
        pageSince = ProcessInfo.processInfo.systemUptime
        if controller == nil { prepareController() }
        activateAudio()
        render()
        controller?.invalidatePlaybackState()
        tick()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func activateAudio() {
        guard !audioActive else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audio.setActive(true)
            audioActive = true
        } catch { trace?("audio " + Self.errorCodes(error)) }
    }

    // AVKit requests must originate from the visible Play/PiP control. The
    // system share sheet may still be dismissing when capture starts.
    func openWindow() {
        guard wantsWindow, !startIssued, controller?.isPictureInPictureActive != true else { return }
        activateAudio()
        tick()
        guard ready, let pip = controller else {
            onFailure?("字幕预览正在准备，请稍后再点。")
            return
        }
        startIssued = true
        issuedAt = ProcessInfo.processInfo.systemUptime
        ready = false
        onReady?(false)
        trace?("pip.request " + stateDescription)
        pip.startPictureInPicture()
    }

    private var stateDescription: String {
        let scene = preview?.window?.windowScene?.activationState.rawValue ?? -9
        return "scene=\(scene) attached=\(preview?.window != nil) frame=\(layer?.isReadyForDisplay == true) possible=\(controller?.isPictureInPicturePossible == true) audio=\(audioActive)"
    }

    private static func errorCodes(_ error: Error) -> String {
        var value: NSError? = error as NSError
        var codes: [String] = []
        for _ in 0..<4 {
            guard let current = value else { break }
            codes.append("\(current.domain)(\(current.code))")
            value = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes.joined(separator: " / ")
    }

    func stop() {
        wantsWindow = false
        ticker?.cancel()
        ticker = nil
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
        ready = false
        startIssued = false
        previous = []
        pages = []
        page = 0
        layer?.sampleBufferRenderer.flush()
        render()
        if audioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioActive = false
        }
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
        guard wantsWindow else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if startIssued, controller?.isPictureInPictureActive != true, now - issuedAt > 12 {
            startIssued = false
            trace?("pip.timeout " + stateDescription)
            onFailure?("小窗未响应。屏幕仍在共享，可以重试。")
        }
        let available = !startIssued && controller?.isPictureInPicturePossible == true &&
            preview?.window?.windowScene?.activationState == .foregroundActive && layer?.isReadyForDisplay == true
        if ready != available {
            ready = available
            onReady?(available)
            if available { trace?("pip.ready " + stateDescription) }
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
        guard let layer else { return }
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
                                       presentationTimeStamp: timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock()),
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

    nonisolated func pictureInPictureController(_ pip: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            guard wantsWindow, pip === controller else { return }
            startIssued = false
            let codes = Self.errorCodes(error)
            let reason = (error as NSError).localizedFailureReason ?? ""
            trace?("pip.failed " + codes + " " + String(reason.prefix(160)) + " " + stateDescription)
            onFailure?("小窗未能打开（\(codes)）。屏幕仍在共享，可以重试。")
            tick()
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pip: AVPictureInPictureController) {
        Task { @MainActor in
            guard wantsWindow, pip === controller else { return }
            startIssued = false
            trace?("pip.opened " + stateDescription)
            onOpened?()
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
        Task { @MainActor in
            if wantsWindow && pip === controller && !startIssued { onDismiss?() }
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime,
                                                completion: @escaping () -> Void) { completion() }
}
