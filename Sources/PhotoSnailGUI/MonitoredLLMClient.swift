import Foundation
import PhotoSnailCore

/// `LLMClient` decorator that publishes begin/end events to
/// `APIStatusMonitor` around every call it forwards. Lives in the GUI
/// target so `PhotoSnailCore` stays UI-free. `ProcessingEngine` wraps the
/// concrete client returned by `makeLLMClient` with this before handing
/// it to the worker loop.
///
/// Preflight is forwarded untouched because its richer result enum is
/// recorded via `APIStatusMonitor.noteHandshake(...)` at the call site in
/// `ProcessingEngine.runPreflight`. Emitting a generic begin/end pair on
/// top of that would just duplicate the signal.
struct MonitoredLLMClient: LLMClient {
    let inner: any LLMClient

    var providerLabel: String { inner.providerLabel }

    func listModels() async throws -> [LLMModel] {
        let label = inner.providerLabel
        let token = await APIStatusMonitor.shared.begin(
            call: "listModels", model: nil, providerLabel: label
        )
        do {
            let result = try await inner.listModels()
            await APIStatusMonitor.shared.end(token: token, success: true, reason: nil)
            return result
        } catch {
            await APIStatusMonitor.shared.end(
                token: token, success: false, reason: String(describing: error)
            )
            throw error
        }
    }

    func preflight(model: String) async -> LLMPreflightResult {
        // No event emission here — ProcessingEngine.runPreflight records the
        // handshake via noteHandshake which carries the richer enum. A
        // duplicate begin/end would just flicker the tail for no gain.
        await inner.preflight(model: model)
    }

    func generateCaption(model: String,
                         prompt: String,
                         imageData: Data,
                         sourcePixelWidth: Int,
                         sourcePixelHeight: Int) async throws -> CaptionResult {
        let label = inner.providerLabel
        let token = await APIStatusMonitor.shared.begin(
            call: "generateCaption", model: model, providerLabel: label
        )
        do {
            let result = try await inner.generateCaption(
                model: model,
                prompt: prompt,
                imageData: imageData,
                sourcePixelWidth: sourcePixelWidth,
                sourcePixelHeight: sourcePixelHeight
            )
            await APIStatusMonitor.shared.end(token: token, success: true, reason: nil)
            return result
        } catch {
            await APIStatusMonitor.shared.end(
                token: token, success: false, reason: String(describing: error)
            )
            throw error
        }
    }

    func generateText(model: String, prompt: String) async throws -> LLMTextResult {
        let label = inner.providerLabel
        let token = await APIStatusMonitor.shared.begin(
            call: "generateText", model: model, providerLabel: label
        )
        do {
            let result = try await inner.generateText(model: model, prompt: prompt)
            await APIStatusMonitor.shared.end(token: token, success: true, reason: nil)
            return result
        } catch {
            await APIStatusMonitor.shared.end(
                token: token, success: false, reason: String(describing: error)
            )
            throw error
        }
    }
}
