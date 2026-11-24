import Combine
import CoreImage
import ImageIO
import ScreenCaptureKit
import UIKit

private final class OneGameFrame: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "gamelens.one-frame", qos: .userInitiated)
    private var backgroundSince: TimeInterval?
    private var sent = false
    private let deliver: (CGImage) -> Void

    init(_ deliver: @escaping (CGImage) -> Void) { self.deliver = deliver }

    func gameVisible(_ visible: Bool) {
        queue.async {
            if !visible { self.backgroundSince = nil }
            else if self.backgroundSince == nil { self.backgroundSince = ProcessInfo.processInfo.systemUptime }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !sent, let since = backgroundSince,
              ProcessInfo.processInfo.systemUptime - since >= 1.8,
              sample.isValid, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let raw = (attachments?.first?[.videoOrientation] as? NSNumber)?.uint32Value
        let orientation = raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let frame = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        guard let cg = CIContext(options: [.cacheIntermediates: false]).createCGImage(frame, from: frame.extent) else { return }
        sent = true
        deliver(cg)
    }
}

@MainActor
final class CaptureOnce: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    enum Phase { case idle, picking, waiting, reading, preview }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = ""
    @Published private(set) var preview: UIImage?
    let pack = GameLexicon.load()
    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private var output: OneGameFrame?
    private var ticket = UUID()
    private var inBackground = false
    private var observing = false
    private var captured: CGImage?
    private var timeout: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(locked),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }
    @objc private func locked() { clear() }

    func begin() {
        guard phase == .idle else { return }
        ticket = UUID()
        var options = SCContentSharingPickerConfiguration()
        options.showsMicrophoneControl = false
        picker.defaultConfiguration = options
        picker.add(self)
        observing = true
        picker.isActive = true
        phase = .picking
        message = "在苹果的提示中点「共享整个屏幕」。译镜取到一张后就会停止共享。"
        picker.present()
    }

    func gameVisibility(background: Bool) {
        inBackground = background
        output?.gameVisible(background)
        if !background { readWhenVisible() }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for existing: SCStream?) {
        Task { @MainActor in
            guard existing == nil, phase == .picking else { return }
            await start(filter)
        }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in if phase == .picking { clear("已取消取图。") } }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in if phase == .picking { clear(error.localizedDescription) } }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in if self.stream === stream { clear("取图已结束，请再试一次。") } }
    }

    private func start(_ filter: SCContentFilter) async {
        let id = ticket
        phase = .waiting
        let out = OneGameFrame { [weak self] frame in
            Task { @MainActor in self?.got(frame, id: id) }
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let current = SCStream(filter: filter, configuration: config, delegate: self)
        output = out
        stream = current
        do {
            try current.addStreamOutput(out, type: .screen, sampleHandlerQueue: out.queue)
            try await current.startCapture()
            guard ticket == id, phase == .waiting else { try? await current.stopCapture(); return }
            out.gameVisible(inBackground)
            message = "打开要看的游戏菜单，等两秒，再切回译镜看原位中文。"
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 35_000_000_000)
                if !Task.isCancelled, let self, self.ticket == id, self.phase == .waiting {
                    self.clear("未取得游戏画面，共享已停止。")
                }
            }
            if !inBackground { openGame() }
        } catch {
            if ticket == id { clear("无法取图。\(error.localizedDescription)") }
        }
    }

    private func got(_ image: CGImage, id: UUID) {
        guard id == ticket, phase == .waiting else { return }
        captured = image
        phase = .reading
        message = "正在识别画面上的按钮…"
        let current = detachStream()
        Task {
            if let current { try? await current.stopCapture() }
            if id == ticket { readWhenVisible() }
        }
    }

    private func readWhenVisible() {
        guard !inBackground, phase == .reading, let image = captured, reader == nil else { return }
        captured = nil
        let id = ticket
        let personal = pack
        reader = Task {
            do {
                let result = try await ButtonFrame.translate(image, pack: personal)
                guard id == ticket, !Task.isCancelled else { return }
                guard let output = UIImage(data: result.jpeg) else { throw ButtonFrame.Problem.render }
                preview = output
                message = "已标出 \(result.count) 处中文 · 词库命中 \(result.hits) 处"
                phase = .preview
                reader = nil
                rotateForPreview(output.size)
            } catch {
                if id == ticket { clear(error.localizedDescription) }
            }
        }
    }

    private func rotateForPreview(_ size: CGSize) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let orientation: UIInterfaceOrientationMask = size.width > size.height ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
    }

    func openGame() {
        guard let url = pack.gameURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { Task { @MainActor in self.message = "请从屏幕底边横扫切回游戏。" } }
        }
    }

    func returnToGame() { clear(); openGame() }

    private func detachStream() -> SCStream? {
        timeout?.cancel()
        timeout = nil
        if observing { picker.remove(self); picker.isActive = false; observing = false }
        output?.gameVisible(false)
        output = nil
        let old = stream
        stream = nil
        return old
    }

    func clear(_ reason: String = "") {
        ticket = UUID()
        let old = detachStream()
        if let old { Task { try? await old.stopCapture() } }
        reader?.cancel()
        reader = nil
        captured = nil
        preview = nil
        message = reason
        phase = .idle
    }
}
