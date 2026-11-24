import AppIntents
import UniformTypeIdentifiers

struct TranslateGameButtons: AppIntent {
    static var title: LocalizedStringResource = "在原位翻译游戏按钮"
    static var description = IntentDescription("把一张游戏画面的日文按钮翻译为简体中文，返回同一布局的预览图。")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "游戏画面", supportedContentTypes: [.image])
    var frame: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("在 \(.$frame) 原位显示中文")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let image = try ButtonFrame.decode(frame.data)
        let output = try await ButtonFrame.translate(image, pack: GameLexicon.load())
        return .result(value: IntentFile(data: output.jpeg, filename: "游戏按钮.jpg", type: .jpeg))
    }
}
