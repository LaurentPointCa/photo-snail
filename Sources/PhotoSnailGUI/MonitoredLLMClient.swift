import Foundation
import PhotoSnailCore

/// `LLMClient` decorator that publishes begin/end events to
/// `APIStatusMonitor` around every call it forwards. Lives in the GUI
/// target so `PhotoSnailCore` stays UI-free. `ProcessingEngine` wraps the
/// concrete client returned by `makeLLMClient` with this before handing
/// it to the worker loop.
///
/// Every protocol method — including `preflight` — emits begin/end pairs.
/// The event drives the status-bar *tail* slot; `noteHandshake` (called
/// separately by `ProcessingEngine.runPreflight`) drives the *pill* with
/// the richer preflight enum. These are complementary, not duplicate:
/// without the preflight event the tail would stay stuck on the last
/// caption/listModels call — including the stale failure message from
/// before a successful retry.
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
        let label = inner.providerLabel
        let token = await APIStatusMonitor.shared.begin(
            call: "preflight", model: model, providerLabel: label
        )
        let result = await inner.preflight(model: model)
        switch result {
        case .ok:
            await APIStatusMonitor.shared.end(token: token, success: true, reason: nil)
        case .unreachable(let reason):
            await APIStatusMonitor.shared.end(
                token: token, success: false, reason: "unreachable: \(reason)"
            )
        case .modelMissing(let installed):
            let hint = installed.isEmpty ? "no models installed" : "model not installed"
            await APIStatusMonitor.shared.end(token: token, success: false, reason: hint)
        }
        return result
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
