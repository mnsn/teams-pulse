import Foundation
import FoundationModels
import PulseCore

/// One-sentence summaries of chats, from Apple's on-device model. Never Private Cloud Compute: the
/// session is created with `SystemLanguageModel.default`, which runs on this Mac, so messages and
/// summaries don't leave it. Summaries live in memory only.
@MainActor
final class Summarizer: ObservableObject {
    enum State: Equatable {
        case loading
        case done(String)
        case failed(String)
    }

    private struct Result {
        var key: String
        var state: State
    }

    @Published private var results: [String: Result] = [:]

    /// Why summaries aren't available, or nil when they are.
    nonisolated static var unavailableReason: String? {
        if #available(macOS 26.0, *) {
            return OnDeviceModel.unavailableReason
        }
        return "Summaries need macOS 26 or later."
    }

    /// The chat's summary, if it covers its current messages.
    func state(for conversation: ConversationSummary) -> State? {
        guard let result = results[conversation.id], result.key == SummaryPrompt.key(for: conversation) else { return nil }
        return result.state
    }

    func summarize(_ conversation: ConversationSummary) {
        let key = SummaryPrompt.key(for: conversation)
        if let result = results[conversation.id], result.key == key, result.state == .loading { return }
        results[conversation.id] = Result(key: key, state: .loading)
        let prompt = SummaryPrompt.prompt(for: conversation)
        Task {
            let state = await Self.summarize(prompt: prompt)
            // A newer request for this chat wins.
            if results[conversation.id]?.key == key {
                results[conversation.id] = Result(key: key, state: state)
            }
        }
    }

    nonisolated static func summarize(prompt: String) async -> State {
        if #available(macOS 26.0, *) {
            return await OnDeviceModel.summarize(prompt)
        }
        return .failed("Summaries need macOS 26 or later.")
    }
}

@available(macOS 26.0, *)
private enum OnDeviceModel {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to summarize chats."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready."
        case .unavailable:
            return "Apple Intelligence isn't available."
        }
    }

    static func summarize(_ prompt: String) async -> Summarizer.State {
        if let reason = unavailableReason { return .failed(reason) }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: SummaryPrompt.instructions)
        do {
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 120)
            )
            let text = SummaryPrompt.clean(response.content)
            return text.isEmpty ? .failed("Apple Intelligence gave no summary.") : .done(text)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale:
                return .failed("Apple Intelligence can't summarize this language yet.")
            case .guardrailViolation, .refusal:
                return .failed("Apple Intelligence wouldn't summarize this chat.")
            case .exceededContextWindowSize:
                return .failed("This chat is too long to summarize.")
            case .assetsUnavailable:
                return .failed("Apple Intelligence is still getting ready.")
            case .rateLimited, .concurrentRequests:
                return .failed("Apple Intelligence is busy. Try again in a moment.")
            default:
                return .failed("Couldn't summarize this chat.")
            }
        } catch {
            return .failed("Couldn't summarize this chat.")
        }
    }
}
