import SwiftUI
import Translation

@main
struct GameLensLiveApp: App {
    var body: some Scene {
        WindowGroup { LiveView() }
    }
}

struct LiveView: View {
    @StateObject private var live = LiveTranslator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("游戏译镜").font(.largeTitle.bold())
            Text("日语 → 简体中文").font(.title3)
            CaptionPreview(captions: live.captions)
                .aspectRatio(2.45, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("简体字幕预览")
            Text(live.message).foregroundStyle(.secondary)
            if !live.lexiconStatus.isEmpty {
                Text(live.lexiconStatus).font(.footnote).foregroundStyle(.secondary)
            }
            if live.awaitingWindow {
                Button("打开字幕小窗") { live.openWindow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!live.windowReady)
            }
            if live.canStart {
                Button("开始实时翻译") { live.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("停止翻译") { live.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(live.isStopping)
            }
        }
        .padding(26)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let ticket = live.downloadRequest {
                Color.clear.translationTask(source: LiveTranslator.japanese,
                                            target: LiveTranslator.chinese) { session in
                    do {
                        try await session.prepareTranslation()
                        await live.languageReady(ticket)
                    } catch {
                        await live.languageFailed(ticket, error: error)
                    }
                }.id(ticket)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            live.setGameVisible(phase == .background)
        }
    }
}
