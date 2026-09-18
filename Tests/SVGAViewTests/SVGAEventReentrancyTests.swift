import Testing
import Foundation
@testable import SVGAView

@Suite(.serialized) @MainActor
struct SVGAEventReentrancyTests {
    @Test(arguments: ["clear", "cancel", "stop"])
    func cancellationFromLoadingStateMustCancelOuterLoad(action: String) async throws {
        let view = SVGAView()
        var cleared = false
        view.onEvent = { event in
            if case .stateChanged(.loading) = event, !cleared {
                cleared = true
                switch action {
                case "cancel": view.cancelLoading()
                case "stop": view.stop()
                default: view.clear()
                }
            }
        }
        var cancelled = false
        do { try await view.load(.named("banner", bundle: .module)) }
        catch is CancellationError { cancelled = true }
        #expect(cancelled)
        #expect(view.state == .idle)
        view.clear()
    }
    @Test func clearFromReadyStateMustSuppressOldReadyEvent() async throws {
        let view = SVGAView()
        var readyAfterClear = 0
        var cleared = false
        view.onEvent = { event in
            if case .stateChanged(.ready) = event {
                cleared = true
                view.clear()
            }
            if case .ready = event, cleared { readyAfterClear += 1 }
        }
        do { try await view.load(.named("banner", bundle: .module), startsPlayback: true) }
        catch is CancellationError {}
        #expect(readyAfterClear == 0)
        #expect(view.state == .idle)
        view.clear()
    }
    @Test func replacementFromFailureStateMustSuppressOldFailureEvent() async throws {
        let view = SVGAView()
        var replaced = false
        var staleFailures = 0
        view.onEvent = { event in
            if case .stateChanged(.failed) = event, !replaced {
                replaced = true
                view.play(.named("banner", bundle: .module))
            }
            if case .loadFailed = event, replaced { staleFailures += 1 }
        }
        do { try await view.load(.named("missing-audit-\(UUID().uuidString)", bundle: .module)) }
        catch {}
        #expect(staleFailures == 0)
        view.clear()
    }
    @Test func replacementFromLoadingStateKeepsNewTaskAndOnlyItsReadyEvent() async throws {
        let view = SVGAView()
        var replaced = false
        var readyCount = 0
        view.onEvent = { event in
            if case .stateChanged(.loading) = event, !replaced {
                replaced = true
                view.play(.named("bubble", bundle: .module))
            }
            if case .ready = event { readyCount += 1 }
        }
        await #expect(throws: CancellationError.self) {
            try await view.load(.named("banner", bundle: .module), startsPlayback: true)
        }
        try await waitForPlayback(view)
        #expect(readyCount == 1)
        let expected = try await SVGAParser.shared.parse(named: "bubble", in: .module)
        #expect(view.intrinsicContentSize == expected.videoSize)
        view.clear()
    }

    @Test(arguments: [true, false])
    func replacementFromIdleDuringClearOrStopKeepsNewLoadingState(clear: Bool) async throws {
        let view = SVGAView()
        view.play(.named("banner", bundle: .module))
        var replaced = false
        view.onEvent = { event in
            if case .stateChanged(.idle) = event, !replaced {
                replaced = true
                view.play(.named("bubble", bundle: .module))
            }
        }
        if clear { view.clear() } else { view.stop() }
        #expect(replaced)
        #expect(view.state == .loading)
        try await waitForPlayback(view)
        view.onEvent = nil
        view.clear()
    }

    @Test func replacementFromStoppedStateSuppressesOldFinishedEvent() {
        let view = SVGAView()
        var replaced = false
        var finishedCount = 0
        view.onEvent = { event in
            if case .stateChanged(.stopped) = event {
                replaced = true
                view.play(.named("bubble", bundle: .module))
            }
            if case .finished = event { finishedCount += 1 }
        }
        // Exercise the same delegate entry used by the engine's natural completion.
        view.svgaPlaybackEngineDidFinishAnimation(SVGAPlaybackEngine())
        #expect(replaced)
        #expect(view.state == .loading)
        #expect(finishedCount == 0)
        view.onEvent = nil
        view.clear()
    }

    private func waitForPlayback(_ view: SVGAView) async throws {
        for _ in 0..<200 {
            if view.state == .playing { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(view.state == .playing)
    }

}
