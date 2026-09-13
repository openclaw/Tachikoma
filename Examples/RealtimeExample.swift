import Foundation
import Tachikoma
import TachikomaAudio

#if canImport(Combine)
/// Embed in a host target that links Tachikoma and TachikomaAudio.
@MainActor
final class RealtimeExample {
    private var conversation: RealtimeConversation?
    private var transcriptTask: Task<Void, Never>?

    func start(configuration: TachikomaConfiguration) async throws {
        await self.stop()
        let conversation = try await startRealtimeConversation(
            model: .custom("gpt-realtime"),
            instructions: "Answer concisely.",
            tools: [timeTool],
            configuration: configuration,
        )
        self.conversation = conversation
        self.transcriptTask = Task {
            for await text in conversation.transcriptUpdates {
                print(text, terminator: "")
            }
        }
    }

    func send(_ text: String) async throws {
        guard let conversation else {
            throw TachikomaError.invalidConfiguration("Start the conversation before sending text")
        }
        try await conversation.sendText(text)
    }

    func stop() async {
        self.transcriptTask?.cancel()
        self.transcriptTask = nil
        await self.conversation?.end()
        self.conversation = nil
    }
}
#endif
