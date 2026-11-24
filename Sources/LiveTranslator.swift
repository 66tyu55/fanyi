import AVFoundation
import Combine
import ScreenCaptureKit
import Translation
import UIKit

@MainActor
final class LiveTranslator: NSObject, ObservableObject, SCContentSharingPickerObserver, SCStreamDelegate {
    static let japanese = Locale.Language(identifier: "ja")
    static let chinese = Locale.Language(identifier: "zh-Hans")
    let captions = Captions()
    @Published private(set) var message = "点开始，共享屏幕后切回游戏。"
    @Published private(set) var downloadRequest: UUID?
    @Published private var phase: Phase = .idle
    var canStart: Bool { phase == .idle }
    var isStopping: Bool { phase == .stopping }

    private enum Phase { case idle, preparing, picking, starting, running, stopping }
    private let picker = SCContentSharingPicker.shared
    private var observing = false
    private var generation = UUID()
    private var stream: SCStream?
    private var reader: ScreenTextReader?
    private var session: TranslationSession?
    private var gameVisible = false
    private var latest: [String] = []
    private var rendered: [String] = []
    private var emptyFrames = 0
    private var worker: Task<Void, Never>?
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []

    override init() {
        super.init()
        captions.onDismiss = { [weak self] in self?.stop() }
        captions.onFailure = { [weak self] error in self?.stop("字幕窗口未启动。\(error)") }
        NotificationCenter.default.addObserver(self, selector: #selector(locked),
                                                name: UIApplication.protectedDataWillBecomeUnavailableNotification,
                                                object: nil)
    }

    @objc private func locked() { stop() }

    func start() {
        guard phase == .idle else { return }
        let ticket = UUID()
        generation = ticket
        phase = .preparing
        message = "正在检查日语和简体中文语言包…"
        Task {
            let availability = await LanguageAvailability().status(from: Self.japanese, to: Self.chinese)
            guard ticket == generation, phase == .preparing else { return }
            switch availability {
            case .installed: languageReady(ticket)
            case .supported:
                message = "首次使用请下载苹果的设备端语言包。"
                downloadRequest = ticket
            default: stop("这台设备当前无法使用日语到简体中文的设备端翻译。")
            }
        }
    }

    func languageFailed(_ ticket: UUID, error: Error) {
        guard ticket == generation, phase == .preparing else { return }
        stop("语言包未就绪。\(error.localizedDescription)")
    }

    func languageReady(_ ticket: UUID) {
        guard ticket == generation, phase == .preparing else { return }
        downloadRequest = nil
        session = TranslationSession(installedSource: Self.japanese, target: Self.chinese)
        var options = SCContentSharingPickerConfiguration()
        options.showsMicrophoneControl = false
        picker.defaultConfiguration = options
        picker.add(self)
        observing = true
        picker.isActive = true
        phase = .picking
        message = "请在系统窗口中选择共享整个屏幕。"
        picker.present()
    }

    func setGameVisible(_ visible: Bool) {
        gameVisible = visible
        reader?.setEnabled(visible && phase == .running)
        if !visible && phase == .running {
            latest = []
            rendered = []
            captions.show([])
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                         for existing: SCStream?) {
        Task { @MainActor in
            if let existing, existing === self.stream, self.phase == .running {
                do { try await existing.updateContentFilter(filter) }
                catch { if self.stream === existing { self.stop(error.localizedDescription) } }
            } else if existing == nil && self.phase == .picking {
                await self.beginCapture(filter)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor existing: SCStream?) {
        Task { @MainActor in
            if existing == nil && self.phase == .picking { self.stop("已取消屏幕共享。") }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            if self.phase == .picking { self.stop("共享窗口未打开。\(error.localizedDescription)") }
        }
    }

    private func beginCapture(_ filter: SCContentFilter) async {
        let ticket = generation
        phase = .starting
        let output = ScreenTextReader { [weak self] values in
            Task { @MainActor in self?.receive(values, ticket: ticket) }
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        stream = newStream
        reader = output
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.deliveryQueue)
            try await newStream.startCapture()
            guard generation == ticket else {
                try? await newStream.stopCapture()
                return
            }
            try captions.start()
            phase = .running
            output.setEnabled(gameVisible)
            message = "切回游戏即可读简体字幕。关闭小窗会结束共享。"
        } catch {
            if generation == ticket { stop("无法启动翻译。\(error.localizedDescription)") }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.stream === stream { self.stop("屏幕共享已结束。") }
        }
    }

    private func receive(_ raw: [String], ticket: UUID) {
        guard ticket == generation, phase == .running, gameVisible else { return }
        // If the OS includes the PiP in a captured frame, ignore our own Chinese subtitles.
        let originals = Set(latest)
        let text = Array(raw.filter { line in
            line != "等待游戏文字" && (originals.contains(line) || !rendered.contains(where: { $0.contains(line) }))
        }.prefix(60))
        if text.isEmpty {
            emptyFrames += 1
            if emptyFrames < 2 { return }
        } else { emptyFrames = 0 }
        guard latest != text else { return }
        latest = text
        displayCached()
        guard !text.isEmpty, worker == nil else { return }
        worker = Task { await self.translateChanges(ticket) }
    }

    private func displayCached() {
        rendered = latest.compactMap { cache[$0] }
        captions.show(rendered)
    }

    private func translateChanges(_ ticket: UUID) async {
        defer { if generation == ticket { worker = nil } }
        guard let session else { return }
        while !Task.isCancelled && ticket == generation {
            let unknown = latest.filter { cache[$0] == nil }.prefix(12)
            if unknown.isEmpty { return }
            let requests = unknown.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
            do {
                let replies = try await session.translations(from: requests)
                guard !Task.isCancelled, generation == ticket else { return }
                for r in replies {
                    guard let key = r.clientIdentifier, unknown.contains(key), !r.targetText.isEmpty else { continue }
                    if cache[key] == nil { cacheOrder.append(key) }
                    cache[key] = r.targetText
                }
                guard unknown.allSatisfy({ cache[$0] != nil }) else {
                    stop("部分文字未得到翻译。请重新开始。")
                    return
                }
                while cacheOrder.count > 350 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                displayCached()
            } catch {
                if generation == ticket { stop("设备端翻译中断。\(error.localizedDescription)") }
                return
            }
        }
    }

    func stop(_ reason: String = "已停止。下次点开始即可。") {
        guard phase != .idle, phase != .stopping else { return }
        phase = .stopping
        generation = UUID()
        downloadRequest = nil
        worker?.cancel()
        worker = nil
        let old = stream
        stream = nil
        reader?.setEnabled(false)
        reader = nil
        if observing {
            picker.remove(self)
            picker.isActive = false
            observing = false
        }
        session = nil
        latest = []
        rendered = []
        cache = [:]
        cacheOrder = []
        emptyFrames = 0
        captions.stop()
        message = reason
        Task {
            if let old { try? await old.stopCapture() }
            phase = .idle
        }
    }
}
