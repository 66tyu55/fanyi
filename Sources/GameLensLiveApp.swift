import SwiftUI
import Translation

@main
struct GameLensLiveApp: App {
    var body: some Scene { WindowGroup { GameLensView() } }
}

struct GameLensView: View {
    @StateObject private var capture = CaptureOnce()
    @Environment(\.scenePhase) private var scenePhase
    @State private var download: TranslationSession.Configuration?
    @State private var languageStatus = ""

    var body: some View {
        Group {
            if let image = capture.preview {
                ZStack(alignment: .bottomTrailing) {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .accessibilityLabel(capture.message)
                    Button(capture.pack.gameURL == nil ? "收起" : "收起，回游戏") {
                        capture.returnToGame()
                    }
                    .buttonStyle(.borderedProminent).padding(10)
                }
                .persistentSystemOverlays(.hidden)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("游戏按钮翻译").font(.largeTitle.bold())
                    Text("日语 → 简体中文").font(.title3)
                    Text("先在游戏中打开要看的菜单，再来取图。看完原位中文，点「收起，回游戏」继续。")
                    if capture.phase == .idle {
                        Button("取一张游戏画面") { capture.begin() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        if capture.phase == .waiting, capture.pack.gameURL != nil {
                            Button("切到游戏取图") { capture.openGame() }.buttonStyle(.borderedProminent)
                        }
                        Button("取消") { capture.clear("已取消取图。") }.buttonStyle(.bordered)
                    }
                    if !capture.message.isEmpty { Text(capture.message).foregroundStyle(.secondary) }
                    if capture.phase == .idle {
                        if !languageStatus.isEmpty { Text(languageStatus).font(.footnote).foregroundStyle(.secondary) }
                        if languageStatus != "设备端语言包已就绪" {
                            Button("准备日语和简中语言包") {
                                download = .init(source: ButtonFrame.japanese, target: ButtonFrame.chinese)
                            }
                        }
                        Text("个人词库 \(capture.pack.count) 条").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading).padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            capture.gameVisibility(background: phase == .background)
        }
        .task {
            if await LanguageAvailability().status(from: ButtonFrame.japanese, to: ButtonFrame.chinese) == .installed {
                languageStatus = "设备端语言包已就绪"
            }
        }
        .translationTask(download) { session in
            do {
                try await session.prepareTranslation()
                languageStatus = "设备端语言包已就绪"
            } catch { languageStatus = "语言包尚未就绪，可再次下载。" }
        }
    }
}
