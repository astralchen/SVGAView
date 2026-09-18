import Foundation
import Testing
@testable import SVGAView

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var isOpen: Bool { opened }
}

@Suite(.serialized)
struct SVGASharedCancellationTests {
    @Test func oneSubscriberCancelsWithoutWaitingForSharedWorker() async throws {
        let requests = SVGASharedRequests<Int>()
        let started = Gate(), release = Gate(), joined = Gate()
        let first = Task {
            try await requests.value(for: "shared", progress: { _, _ in }) { _, progress in
                await progress(0.5)
                await started.open()
                await release.wait()
                return 42
            }
        }
        await started.wait()
        let second = Task {
            try await requests.value(for: "shared", progress: { _, active in
                if active() { await joined.open() }
            }) { _, _ in Issue.record("Duplicate worker"); return -1 }
        }
        await joined.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await release.isOpen == false)
        await release.open()
        #expect(try await second.value == 42)
    }

    @Test func lastCancellationRetainsGenerationUntilCleanupAndRetryUsesNewWorker() async throws {
        let requests = SVGASharedRequests<Int>()
        let started = Gate(), cancelled = Gate(), cleanup = Gate(), nextStarted = Gate()
        let first = Task {
            try await requests.value(for: "same", progress: { _, _ in }) { lease, progress in
                await started.open()
                await withTaskCancellationHandler {
                    await cleanup.wait()
                } onCancel: { Task { await cancelled.open() } }
                await progress(0.9) // Late old progress must not reach the new subscriber.
                try lease.checkCancellation()
                return 1
            }
        }
        await started.wait()
        first.cancel()
        await cancelled.wait()
        let second = Task {
            try await requests.value(for: "same", progress: { value, active in
                if active() { #expect(value == 1) }
            }) { _, _ in await nextStarted.open(); return 2 }
        }
        #expect(await nextStarted.isOpen == false)
        #expect(requests.status(for: "same").isDownloading)
        await cleanup.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == 2)
        #expect(!requests.status(for: "same").isDownloading)
    }

    @Test func preCancellationDoesNotStartOperation() async {
        let requests = SVGASharedRequests<Int>()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await requests.value(for: "pre", progress: { _, _ in }) { _, _ in
                Issue.record("Precancelled operation executed")
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func selectedSuccessSurvivesCancellationDuringFinalProgress() async throws {
        let requests = SVGASharedRequests<Int>()
        let completing = Gate(), release = Gate()
        let task = Task {
            try await requests.value(for: "done", progress: { _, active in
                if active() { await completing.open(); await release.wait() }
            }) { _, _ in 7 }
        }
        await completing.wait()
        task.cancel()
        await release.open()
        #expect(try await task.value == 7)
    }
}

/// Network events control response delivery; no sleep determines cancellation success.
final class SVGACancellationURLProtocol: URLProtocol, @unchecked Sendable {
    final class Control: @unchecked Sendable {
        fileprivate let started = Gate(), stopped = Gate()
        let queue = DispatchQueue(label: "cancellation.protocol")
        var instance: SVGACancellationURLProtocol?
        var starts = 0
        var stops = 0
        let payload: Data
        init(payload: Data) { self.payload = payload }
        func finish() {
            queue.async {
                guard let instance = self.instance else { return }
                instance.client?.urlProtocol(instance, didLoad: self.payload.suffix(self.payload.count - self.payload.count / 2))
                instance.client?.urlProtocolDidFinishLoading(instance)
                self.instance = nil
            }
        }
        var counts: (Int, Int) { queue.sync { (starts, stops) } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var controls: [URL: Control] = [:]
    static func install(_ control: Control) -> URL {
        let url = URL(string: "https://cancel.test/\(UUID().uuidString).svga")!
        lock.lock(); controls[url] = control; lock.unlock()
        return url
    }
    private var control: Control? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return request.url.flatMap { Self.controls[$0] }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cancel.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let control else { return }
        control.queue.sync {
            control.instance = self
            control.starts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Length": "\(control.payload.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: control.payload.prefix(control.payload.count / 2))
            Task { await control.started.open() }
        }
    }
    override func stopLoading() {
        guard let control else { return }
        control.queue.sync {
            control.stops += 1
            control.instance = nil
            Task { await control.stopped.open() }
        }
    }
}

@Suite(.serialized)
struct SVGANetworkCancellationTests {
    private func parser() -> SVGAParser {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SVGACancellationURLProtocol.self]
        return SVGAParser(configuration: configuration)
    }
    private func payload() throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: "banner", withExtension: "svga")))
    }
    @Test func lastCancellationStopsTransportAndRetryPublishesCompleteCache() async throws {
        let parser = parser()
        let control = SVGACancellationURLProtocol.Control(payload: try payload())
        let url = SVGACancellationURLProtocol.install(control)
        let first = Task { try await parser.parse(url: url) }
        await control.started.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await control.stopped.wait()
        #expect(control.counts.1 == 1)
        #expect(await parser.cacheStatus(url: url) == .missing)
        let received = Gate()
        let retry = Task {
            try await parser.parse(url: url) { value in
                if value > 0 { Task { await received.open() } }
            }
        }
        await received.wait()
        control.finish()
        let entity = try await retry.value
        #expect(entity.frames > 0)
        #expect(control.counts.0 == 2)
        guard case .cached(let path) = await parser.cacheStatus(url: url) else {
            Issue.record("Successful parse missing cache"); return
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cached = try await parser.parse(url: url)
        #expect(cached === entity)
        let precancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await parser.parse(url: url)
        }
        await #expect(throws: CancellationError.self) { try await precancelled.value }
        #expect(control.counts.0 == 2)
    }
    @Test func cancelledSubscriberExitsBeforeOtherNetworkSubscriber() async throws {
        let parser = parser()
        let control = SVGACancellationURLProtocol.Control(payload: try payload())
        let url = SVGACancellationURLProtocol.install(control)
        let joined = Gate()
        let first = Task { try await parser.parse(url: url) }
        await control.started.wait()
        let second = Task {
            try await parser.parse(url: url) { value in
                if value > 0 { Task { await joined.open() } }
                #expect(value != 1)
            }
        }
        await joined.wait()
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(control.counts.1 == 0)
        control.finish()
        #expect(try await first.value.frames > 0)
        #expect(control.counts.0 == 1)
        if case .cached(let path) = await parser.cacheStatus(url: url) { try? FileManager.default.removeItem(atPath: path) }
    }
}

@Suite(.serialized) @MainActor
struct SVGAViewCancellationTests {
    private func setup() throws -> (SVGACancellationURLProtocol.Control, URL) {
        SVGAURLSessionTestHooks.protocolClasses = [ChunkedSVGAURLProtocol.self, NeverFinishingSVGAURLProtocol.self, SVGACancellationURLProtocol.self]
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "banner", withExtension: "svga")))
        let control = SVGACancellationURLProtocol.Control(payload: data)
        return (control, SVGACancellationURLProtocol.install(control))
    }
    @Test func directLoadCancellationThrowsNativeErrorAndReportsCurrentFailure() async throws {
        let (control, url) = try setup()
        let view = SVGAView()
        var failures = 0
        view.onEvent = { event in
            if case .loadFailed(.cancelled) = event { failures += 1 }
        }
        let task = Task { try await view.load(remoteURL: url) }
        await control.started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(view.state == .failed(.cancelled))
        #expect(failures == 1)
        #expect(control.counts.1 == 1)
    }
    @Test(arguments: [true, false])
    func clearOrReplaceInvalidatesDirectAsyncLoad(replace: Bool) async throws {
        let (control, url) = try setup()
        let view = SVGAView()
        var failures = 0
        view.onEvent = { if case .loadFailed = $0 { failures += 1 } }
        let old = Task { try await view.load(remoteURL: url, startsPlayback: true) }
        await control.started.wait()
        if replace { try await view.load(.named("banner", bundle: .module)) }
        else { view.clear() }
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(view.state == (replace ? .ready : .idle))
        #expect(failures == 0)
        #expect(control.counts.1 == 1)
    }
    @Test(arguments: [true, false])
    func preloadAndViewLoadCancelIndependently(cancelView: Bool) async throws {
        let (control, url) = try setup()
        let prefetch = Task { try await SVGAView.preload(remoteURL: url) }
        await control.started.wait()
        let view = SVGAView()
        let joined = Gate()
        view.onEvent = { if case .downloadProgress(let value) = $0, value > 0 { Task { await joined.open() } } }
        let load = Task { try await view.load(remoteURL: url) }
        await joined.wait()
        if cancelView {
            view.cancelLoading()
            await #expect(throws: CancellationError.self) { try await load.value }
        } else {
            prefetch.cancel()
            await #expect(throws: CancellationError.self) { try await prefetch.value }
        }
        #expect(control.counts.1 == 0)
        control.finish()
        if cancelView { try await prefetch.value; #expect(view.state == .idle) }
        else { try await load.value; #expect(view.state == .ready) }
        #expect(control.counts.0 == 1)
        view.clear()
    }
    @Test func preCancelledPublicAPIsDoNotChangeViewOrStartNetwork() async throws {
        let (control, url) = try setup()
        let view = SVGAView()
        let preload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SVGAView.preload(remoteURL: url)
        }
        let load = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await view.load(remoteURL: url)
        }
        await #expect(throws: CancellationError.self) { try await preload.value }
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(view.state == .idle)
        #expect(control.counts.0 == 0)
    }
}

@Suite(.serialized)
struct SVGAParsePublicationCancellationTests {
    @Test func cancellationAfterParsingDiscardsOnlyItsStagingDirectory() async throws {
        let prepared = Gate(), release = Gate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parser = SVGAParser(cacheDirectory: directory, beforeCacheCommit: {
            await prepared.open()
            await release.wait()
        })
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "banner", withExtension: "svga")))
        let key = UUID().uuidString
        let task = Task { try await parser.parse(data: data, cacheKey: key) }
        await prepared.wait()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".staging-") })
        task.cancel()
        #expect(await parser.cacheStatus(dataCacheKey: key) != .cached(localPath: directory.appendingPathComponent(key).path))
        await release.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await parser.cacheStatus(dataCacheKey: key) == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let entity = try await parser.parse(data: data, cacheKey: key)
        #expect(entity.frames > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [key])
    }
}
