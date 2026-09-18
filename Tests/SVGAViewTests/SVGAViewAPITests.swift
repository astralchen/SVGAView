import Foundation
import Testing
import UIKit
@testable import SVGAView

private func makeSolidTestImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
}

private func layerContentsIdentical(_ contents: Any?, to image: CGImage) -> Bool {
    guard let contents else { return false }
    return contents as AnyObject === image
}

@MainActor
private func findContentLayer(in layer: CALayer?, imageKey: String) -> SVGAContentLayer? {
    guard let layer else { return nil }
    if let contentLayer = layer as? SVGAContentLayer, contentLayer.imageKey == imageKey {
        return contentLayer
    }
    for sublayer in layer.sublayers ?? [] {
        if let match = findContentLayer(in: sublayer, imageKey: imageKey) {
            return match
        }
    }
    return nil
}

final class NeverFinishingSVGAURLProtocol: URLProtocol {
    nonisolated(unsafe) static var started = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "svga-never.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.started = true
    }

    override func stopLoading() {}
}

@MainActor
@Test
func svgaViewPublicAPITypesAreUsable() {
    let view = SVGAView()
    var observedEvents: [SVGAViewEvent] = []
    view.onEvent = { observedEvents.append($0) }

    let request = URLRequest(url: URL(string: "https://example.com/effect.svga")!)
    let source = SVGAViewSource.request(request)

    #expect(view.state == .idle)
    #expect(source.debugDescription.contains("request"))
    #expect(SVGAViewError.resourceNotFound("missing").errorDescription?.isEmpty == false)
    view.setImage(makeSolidTestImage(), forKey: "avatar")
    view.setAttributedText(NSAttributedString(string: "name"), forKey: "nickname")
    view.setDrawingBlock({ _, _ in }, forKey: "badge")
    view.setHidden(true, forKey: "badge")
    view.removeImage(forKey: "avatar")
    view.removeAttributedText(forKey: "nickname")
    view.removeDrawingBlock(forKey: "badge")
    view.removeHidden(forKey: "badge")
    view.clearDynamicContent()
    #expect(observedEvents.isEmpty)
}

@MainActor
@Test
func svgaViewRenamedPublicAPIsAreUsable() {
    let view = SVGAView()
    view.autoPlay = false
    view.resourcePath = " "
    view.fillMode = .lastFrame

    let remoteURL = URL(string: "https://example.com/effect.svga")!
    let source = SVGAViewSource.remoteURL(remoteURL)

    view.seek(toFrame: 0, startsPlayback: false)
    view.seek(toProgress: 0.5, startsPlayback: false)

    #expect(view.resourcePath == " ")
    #expect(source.debugDescription.contains("remoteURL"))
}

@MainActor
@Test
func svgaViewCanInitializeWithResourcePath() {
    let view = SVGAView(resourcePath: " ")

    #expect(view.resourcePath == " ")
    #expect(view.state == .idle)
}

@MainActor
@Test
func svgaViewOptimizedPublicAPIsAreUsable() async throws {
    guard let fileURL = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }
    let remoteURL = URL(string: "https://example.com/effect.svga")!

    _ = SVGAView(named: "banner", in: .module)
    _ = SVGAView(fileURL: fileURL)
    _ = SVGAView(remoteURL: remoteURL)

    let view = SVGAView()
    var configuredContent = false
    try await view.load(.named("banner", bundle: .module), startsPlayback: false) { content in
        configuredContent = true
        content.setHidden(true, forKey: "badge")
    }

    view.start()
    view.pause()
    view.start(range: 0..<1, reverse: false)
    view.stop()

    #expect(configuredContent)
    #expect(view.state == .stopped)
}

@MainActor
@Test
func loadSourceCanStartPlaybackExplicitly() async throws {
    let view = SVGAView()

    try await view.load(.named("banner", bundle: .module), startsPlayback: true)

    #expect(view.state == .playing)
}

@MainActor
@Test
func playAlwaysStartsPlaybackEvenWhenAutoPlayIsDisabled() async throws {
    let view = SVGAView()
    view.autoPlay = false

    view.play(.named("banner", bundle: .module))

    for _ in 0..<200 where view.state != .playing {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(view.state == .playing)
}

@MainActor
@Test
func preloadRequestCachesRemoteDataWithoutAView() async throws {
    guard let url = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }
    ChunkedSVGAURLProtocol.responseData = try Data(contentsOf: url)
    SVGAURLSessionTestHooks.protocolClasses = [
        ChunkedSVGAURLProtocol.self,
        NeverFinishingSVGAURLProtocol.self,
        SVGACancellationURLProtocol.self
    ]
    let preloadURL = URL(string: "https://svga-progress.test/preload-\(UUID().uuidString).svga")!
    ChunkedSVGAURLProtocol.resetRequestCount(for: preloadURL)
    let request = URLRequest(
        url: preloadURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 5
    )
    let recorder = ProgressRecorder()

    try await SVGAView.preload(.request(request)) { progress in
        recorder.record(progress)
    }

    let view = SVGAView()
    try await view.load(.request(request))

    let values = recorder.values
    #expect(ChunkedSVGAURLProtocol.requestCount(for: preloadURL) == 1)
    #expect(view.state == .ready)
    #expect(values.contains { $0 > 0 && $0 < 1 }, "expected an intermediate progress value, got \(values)")
    #expect(values.last == 1.0, "expected final progress to be 1.0, got \(values)")
}

@MainActor
@Test
func remoteCacheStatusCanBeQueriedWithoutLoadingAView() async throws {
    guard let url = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }
    ChunkedSVGAURLProtocol.responseData = try Data(contentsOf: url)
    SVGAURLSessionTestHooks.protocolClasses = [
        ChunkedSVGAURLProtocol.self,
        NeverFinishingSVGAURLProtocol.self,
        SVGACancellationURLProtocol.self
    ]
    let preloadURL = URL(string: "https://svga-progress.test/cache-state-\(UUID().uuidString).svga")!
    ChunkedSVGAURLProtocol.resetRequestCount(for: preloadURL)
    let request = URLRequest(
        url: preloadURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 5
    )

    #expect(await SVGAView.cacheStatus(remoteURL: preloadURL) == .missing)
    #expect(await SVGAView.cacheStatus(request: request) == .missing)

    try await SVGAView.preload(request: request)

    let remoteStatus = await SVGAView.cacheStatus(remoteURL: preloadURL)
    let requestStatus = await SVGAView.cacheStatus(request: request)
    guard case .cached(let remotePath) = remoteStatus else {
        Issue.record("Expected cached remote status, got \(remoteStatus)")
        return
    }
    guard case .cached(let requestPath) = requestStatus else {
        Issue.record("Expected cached request status, got \(requestStatus)")
        return
    }
    #expect(remotePath == requestPath)
    #expect(FileManager.default.fileExists(atPath: remotePath))
    #expect(ChunkedSVGAURLProtocol.requestCount(for: preloadURL) == 1)
}

@MainActor
@Test
func concurrentPreloadAndViewLoadShareInFlightRequest() async throws {
    guard let url = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }
    ChunkedSVGAURLProtocol.responseData = try Data(contentsOf: url)
    SVGAURLSessionTestHooks.protocolClasses = [
        ChunkedSVGAURLProtocol.self,
        NeverFinishingSVGAURLProtocol.self,
        SVGACancellationURLProtocol.self
    ]
    let preloadURL = URL(string: "https://svga-progress.test/single-flight-\(UUID().uuidString).svga")!
    ChunkedSVGAURLProtocol.resetRequestCount(for: preloadURL)
    ChunkedSVGAURLProtocol.setResponseDelay(1.0, for: preloadURL)
    let request = URLRequest(
        url: preloadURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 5
    )
    let preloadTask = Task.detached {
        try await SVGAView.preload(.request(request))
    }

    for _ in 0..<1_000 where ChunkedSVGAURLProtocol.requestCount(for: preloadURL) == 0 {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(ChunkedSVGAURLProtocol.requestCount(for: preloadURL) == 1)
    let status = await SVGAView.cacheStatus(request: request)
    if case .downloading(let progress) = status {
        if let progress {
            #expect(progress >= 0.0 && progress <= 1.0)
        }
    } else {
        Issue.record("Expected downloading status, got \(status)")
    }

    let view = SVGAView()
    try await view.load(.request(request))
    try await preloadTask.value

    #expect(ChunkedSVGAURLProtocol.requestCount(for: preloadURL) == 1)
    #expect(view.state == .ready)
}

@MainActor
@Test
func concurrentPreloadAndViewLoadBothReceiveInFlightProgress() async throws {
    guard let url = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }
    ChunkedSVGAURLProtocol.responseData = try Data(contentsOf: url)
    SVGAURLSessionTestHooks.protocolClasses = [
        ChunkedSVGAURLProtocol.self,
        NeverFinishingSVGAURLProtocol.self,
        SVGACancellationURLProtocol.self
    ]
    let preloadURL = URL(string: "https://svga-progress.test/in-flight-progress-\(UUID().uuidString).svga")!
    ChunkedSVGAURLProtocol.resetRequestCount(for: preloadURL)
    ChunkedSVGAURLProtocol.setResponseDelay(1.0, for: preloadURL)
    let request = URLRequest(
        url: preloadURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 5
    )
    let preloadRecorder = ProgressRecorder()
    let viewRecorder = ProgressRecorder()
    let preloadTask = Task.detached {
        try await SVGAView.preload(.request(request)) { progress in
            preloadRecorder.record(progress)
        }
    }

    for _ in 0..<1_000 where !preloadRecorder.values.contains(where: { $0 > 0 && $0 < 1 }) {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(preloadRecorder.values.contains { $0 > 0 && $0 < 1 })
    let status = await SVGAView.cacheStatus(request: request)
    if case .downloading(let progress?) = status {
        #expect(progress > 0.0 && progress < 1.0)
    } else {
        Issue.record("Expected downloading status with progress, got \(status)")
    }

    let view = SVGAView()
    view.onEvent = { event in
        guard case .downloadProgress(let progress) = event else { return }
        viewRecorder.record(progress)
    }
    try await view.load(.request(request))
    try await preloadTask.value

    for _ in 0..<200 where viewRecorder.values.last != 1.0 {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let viewValues = viewRecorder.values
    #expect(ChunkedSVGAURLProtocol.requestCount(for: preloadURL) == 1)
    #expect(view.state == .ready)
    #expect(viewValues.contains { $0 > 0 && $0 < 1 }, "expected an intermediate progress value, got \(viewValues)")
    #expect(viewValues.last == 1.0, "expected final progress to be 1.0, got \(viewValues)")
}

@MainActor
@Test
func resourcePathInitializerUsesLoadedVideoSizeWhenFrameIsZero() async throws {
    let entity = try await SVGAParser.shared.parse(named: "banner", in: .module)
    guard let fileURL = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }

    let view = SVGAView(resourcePath: fileURL.absoluteString)

    for _ in 0..<200 where view.intrinsicContentSize != entity.videoSize {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(view.frame.size == entity.videoSize)
}

@MainActor
@Test
func localSourceInitializersUseLoadedVideoSizeWhenFrameIsZero() async throws {
    let entity = try await SVGAParser.shared.parse(named: "banner", in: .module)
    guard let fileURL = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }

    let namedView = SVGAView(named: "banner", in: .module)
    let fileView = SVGAView(fileURL: fileURL)

    for _ in 0..<200 where namedView.frame.size != entity.videoSize || fileView.frame.size != entity.videoSize {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(namedView.frame.size == entity.videoSize)
    #expect(fileView.frame.size == entity.videoSize)
}

@MainActor
@Test
func svgaViewIntrinsicContentSizeMatchesLoadedVideoSize() async throws {
    let entity = try await SVGAParser.shared.parse(named: "banner", in: .module)
    let view = SVGAView()
    view.autoPlay = false

    #expect(view.intrinsicContentSize == UIImageView().intrinsicContentSize)

    try await view.load(named: "banner", in: .module)

    #expect(view.intrinsicContentSize == entity.videoSize)
    #expect(view.sizeThatFits(CGSize(width: 1, height: 1)) == entity.videoSize)
}

@MainActor
@Test
func loadNamedAwaitsReadyState() async throws {
    let view = SVGAView()
    view.autoPlay = false
    var observedEvents: [SVGAViewEvent] = []
    view.onEvent = { observedEvents.append($0) }

    try await view.load(named: "banner", in: .module)

    #expect(view.state == .ready)
    #expect(observedEvents == [
        .stateChanged(.loading),
        .stateChanged(.ready),
        .ready
    ])
}

@MainActor
@Test
func resourcePathLoadingIsDeferredUntilAfterPropertySet() async throws {
    guard let fileURL = Bundle.module.url(forResource: "banner", withExtension: "svga") else {
        throw SVGAParserError.resourceNotFound("banner.svga")
    }
    let view = SVGAView()
    view.autoPlay = false

    view.resourcePath = fileURL.absoluteString

    #expect(view.state == .idle)
    for _ in 0..<200 where view.state != .ready {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(view.state == .ready)
}

@MainActor
@Test
func playbackControlsUpdateState() async throws {
    let view = SVGAView()
    view.autoPlay = false

    try await view.load(named: "banner", in: .module)

    view.start()
    #expect(view.state == .playing)

    view.pause()
    #expect(view.state == .paused)

    view.seek(toFrame: 0, startsPlayback: false)
    #expect(view.state == .paused)

    view.seek(toProgress: 0.2, startsPlayback: true)
    #expect(view.state == .playing)

    view.stop()
    #expect(view.state == .stopped)
}

@MainActor
@Test
func finishedAnimationUpdatesStateBeforeCallback() async throws {
    let view = SVGAView()
    view.autoPlay = false
    view.loops = 1
    view.clearsAfterStop = false
    var callbackState: SVGAViewState?
    view.onEvent = { event in
        guard case .finished = event else { return }
        callbackState = view.state
    }

    try await view.load(named: "banner", in: .module)
    view.start(range: 0..<1, reverse: false)
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(callbackState == .stopped)
    #expect(view.state == .stopped)
}

@MainActor
@Test
func runtimeDynamicContentMethodsUpdateLoadedLayers() async throws {
    let entity = try await SVGAParser.shared.parse(named: "banner", in: .module)
    guard let sprite = entity.sprites.first(where: { sprite in
        let bitmapKey = (sprite.imageKey as NSString).deletingPathExtension
        return entity.images[bitmapKey] != nil
    }) else {
        throw SVGAParserError.resourceNotFound("bitmap sprite")
    }
    let bitmapKey = (sprite.imageKey as NSString).deletingPathExtension
    guard let originalCGImage = entity.images[bitmapKey]?.cgImage else {
        throw SVGAParserError.resourceNotFound("bitmap image")
    }

    let player = SVGAPlaybackEngine()
    player.videoEntity = entity
    guard let contentLayer = findContentLayer(in: player.renderLayer, imageKey: sprite.imageKey) else {
        throw SVGAParserError.resourceNotFound("content layer")
    }

    let replacementImage = makeSolidTestImage()
    guard let replacementCGImage = replacementImage.cgImage else {
        throw SVGAParserError.resourceNotFound("replacement bitmap")
    }
    player.setImage(replacementImage, forKey: bitmapKey)
    #expect(layerContentsIdentical(contentLayer.bitmapLayer?.contents, to: replacementCGImage))

    player.removeImage(forKey: sprite.imageKey)
    #expect(layerContentsIdentical(contentLayer.bitmapLayer?.contents, to: originalCGImage))

    player.setAttributedText(NSAttributedString(string: "nickname"), forKey: bitmapKey)
    #expect(contentLayer.textLayer?.string != nil)
    player.removeAttributedText(forKey: sprite.imageKey)
    #expect(contentLayer.textLayer == nil)

    player.setDrawingBlock({ _, _ in }, forKey: bitmapKey)
    #expect(contentLayer.dynamicDrawingBlock != nil)
    player.removeDrawingBlock(forKey: sprite.imageKey)
    #expect(contentLayer.dynamicDrawingBlock == nil)

    player.setHidden(true, forKey: sprite.imageKey)
    #expect(contentLayer.dynamicHidden)
    player.removeHidden(forKey: bitmapKey)
    #expect(!contentLayer.dynamicHidden)

    player.setImage(replacementImage, forKey: sprite.imageKey)
    player.setAttributedText(NSAttributedString(string: "clear"), forKey: sprite.imageKey)
    player.setDrawingBlock({ _, _ in }, forKey: sprite.imageKey)
    player.setHidden(true, forKey: sprite.imageKey)
    player.clearDynamicContent()

    #expect(layerContentsIdentical(contentLayer.bitmapLayer?.contents, to: originalCGImage))
    #expect(contentLayer.textLayer == nil)
    #expect(contentLayer.dynamicDrawingBlock == nil)
    #expect(!contentLayer.dynamicHidden)
}

@MainActor
@Test
func playRejectsFileURLThroughRemoteURLAPI() async throws {
    let view = SVGAView()
    var failedError: SVGAViewError?
    view.onEvent = { event in
        guard case .loadFailed(let error) = event else { return }
        failedError = error
    }

    view.play(remoteURL: URL(fileURLWithPath: "/tmp/effect.svga"))
    for _ in 0..<200 {
        if case .failed = view.state {
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(view.state == .failed(.unsupportedURLScheme("file")))
    #expect(failedError == .unsupportedURLScheme("file"))
}

@MainActor
@Test
func clearCancelsPendingLoad() async throws {
    SVGAURLSessionTestHooks.protocolClasses = [
        ChunkedSVGAURLProtocol.self,
        NeverFinishingSVGAURLProtocol.self,
        SVGACancellationURLProtocol.self
    ]

    let view = SVGAView()
    let request = URLRequest(
        url: URL(string: "https://svga-never.test/effect.svga")!,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
    )

    view.play(request: request)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(view.state == .loading)

    view.clear()
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.state == .idle)
}

@MainActor
@Test
func stopCancelsPendingLoad() async throws {
    SVGAURLSessionTestHooks.protocolClasses = [
        ChunkedSVGAURLProtocol.self,
        NeverFinishingSVGAURLProtocol.self,
        SVGACancellationURLProtocol.self
    ]

    let view = SVGAView()
    let request = URLRequest(
        url: URL(string: "https://svga-never.test/stop.svga")!,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
    )

    view.play(request: request)
    try await Task.sleep(nanoseconds: 50_000_000)
    view.stop()

    #expect(view.state == .idle)
}
