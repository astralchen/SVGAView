import Foundation
import UIKit
import XCTest
@testable import Examples
@testable import SVGAView

/// 使用实际示例页和播放器验证下载与播放状态 UI，响应由事件门控，不依赖公网速度。
final class DownloadProgressTests: XCTestCase {
    @MainActor
    func testColdDownloadIgnoresStaleFrameUntilPlaybackStarts() async throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try await waitUntil("新资源下载至 50%") { harness.progress.progress > 0 }
        XCTAssertEqual(harness.player.state, .loading)
        XCTAssertEqual(harness.progress.progress, 0.5, accuracy: 0.01)
        XCTAssertFalse(harness.progressStack.isHidden)

        // 即使外部收到迟到帧，仍在 loading 的新请求也不能隐藏进度。
        harness.player.onEvent?(.frameChanged(0))
        XCTAssertFalse(harness.progressStack.isHidden)
        harness.controls[0].finish()
        try await waitUntil("加载完成后的真实播放帧隐藏进度") {
            harness.player.state == .playing && harness.progressStack.isHidden
        }
    }

    @MainActor
    func testSwitchStopsOldFramesAndCacheReplaySkipsNetwork() async throws {
        let harness = try makeHarness()
        defer { harness.close() }
        try await waitUntil("第一份礼物开始下载") { harness.controls[0].starts == 1 }
        harness.controls[0].finish()
        try await waitUntil("第一份礼物开始播放") {
            harness.player.state == .playing && harness.progressStack.isHidden
        }

        let originalHandler = harness.player.onEvent
        var framesDuringLoading = 0
        harness.player.onEvent = { event in
            if case .frameChanged = event, harness.player.state == .loading { framesDuringLoading += 1 }
            originalHandler?(event)
        }
        harness.select(1)
        try await waitUntil("第二份礼物下载至 50%") { harness.progress.progress > 0 }
        // 观察真实显示刷新周期；网络一直被门控，不能因下载过快而掩盖旧帧。
        let clock = DownloadProgressFrameClock()
        try await waitUntil("观察十二个显示刷新周期") { clock.ticks >= 12 }
        clock.stop()
        XCTAssertEqual(harness.player.state, .loading)
        XCTAssertEqual(framesDuringLoading, 0)
        XCTAssertEqual(harness.progress.progress, 0.5, accuracy: 0.01)
        XCTAssertFalse(harness.progressStack.isHidden)
        print("PROGRESS_FIX loading=true progress=50% oldFrames=\(framesDuringLoading) hidden=\(harness.progressStack.isHidden)")
        let image = UIGraphicsImageRenderer(bounds: harness.controller.view.bounds).image { context in
            harness.controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "切换礼物后仍显示下载进度50%"
        attachment.lifetime = .keepAlways
        add(attachment)

        harness.controls[1].finish()
        try await waitUntil("第二份礼物播放并隐藏进度") {
            harness.player.state == .playing && harness.progressStack.isHidden
        }
        harness.select(1)
        try await waitUntil("缓存重播完成加载") {
            harness.player.state == .playing && harness.progressStack.isHidden
        }
        XCTAssertEqual(harness.controls[1].starts, 1)
        print("PROGRESS_FIX cacheReplayAdditionalRequests=0")
    }

    @MainActor
    func testPauseDuringColdDownloadKeepsButtonConsistentAfterAutoplay() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await waitUntil("下载到一半") { h.progress.progress > 0 }
        let pause = try button("暂停", in: h.controller)
        XCTAssertFalse(pause.isEnabled)
        // 直接发送事件，验证禁用外观之外的动作保护。
        pause.sendActions(for: .touchUpInside)
        XCTAssertEqual(h.player.state, .loading)
        h.controls[0].finish()
        try await waitUntil("资源已自动播放且真实帧已隐藏加载提示") { h.player.state == .playing && h.progressStack.isHidden }
        capture("下载中点暂停后", harness: h)
        print("STATE_AUDIT coldPause player=\(h.player.state) button=\(pause.accessibilityLabel ?? "nil")")
        XCTAssertTrue(pause.isEnabled)
        XCTAssertEqual(pause.accessibilityLabel, "暂停", "正在播放时不能显示继续")
    }

    @MainActor
    func testNetworkFailureShowsErrorAndReplayRetriesSuccessfully() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await waitUntil("下载开始") { h.controls[0].starts == 1 }
        h.controls[0].fail()
        try await waitUntil("错误已显示") { if case .failed = h.player.state { return true }; return false }
        XCTAssertTrue(h.progressStack.isHidden)
        XCTAssertTrue(allViews(h.controller.view).compactMap { ($0 as? UILabel)?.text }.contains("加载失败\n点击重播重试"))
        capture("下载失败提示", harness: h)
        try button("重播", in: h.controller).sendActions(for: .touchUpInside)
        try await waitUntil("重试重新下载") { h.controls[0].starts == 2 && h.progress.progress > 0 }
        XCTAssertFalse(h.progressStack.isHidden)
        h.controls[0].finish()
        try await waitUntil("重试后开始播放") { h.player.state == .playing && h.progressStack.isHidden }
    }

    @MainActor
    func testFailedReplacementCannotRestartPreviousGiftUsingPauseButton() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await finishFirst(h)
        h.select(1)
        try await waitUntil("新资源下载开始") { h.controls[1].starts == 1 }
        h.controls[1].fail()
        try await waitUntil("新资源加载失败") { if case .failed = h.player.state { return true }; return false }
        let failedState = h.player.state
        let pause = try button("暂停", in: h.controller)
        XCTAssertFalse(pause.isEnabled)
        pause.sendActions(for: .touchUpInside)
        pause.sendActions(for: .touchUpInside)
        capture("新礼物失败后操作暂停继续", harness: h)
        print("STATE_AUDIT failedReplacement afterButtons=\(h.player.state)")
        XCTAssertEqual(h.player.state, failedState, "新礼物失败后不能通过暂停继续重新播放旧资源")
        try button("重播", in: h.controller).sendActions(for: .touchUpInside)
        try await waitUntil("失败的新礼物重新下载") { h.controls[1].starts == 2 }
        h.controls[1].finish()
        try await waitUntil("新礼物重试后播放") { h.player.state == .playing && h.progressStack.isHidden }
        XCTAssertTrue(pause.isEnabled)
    }

    @MainActor
    func testReplayWhileDownloadingCancelsOldRequestAndStartsNewOne() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await waitUntil("首次下载开始") { h.controls[0].starts == 1 }
        try button("重播", in: h.controller).sendActions(for: .touchUpInside)
        try await waitUntil("旧请求取消并重新下载") { h.controls[0].starts == 2 && h.controls[0].stops >= 1 }
        XCTAssertEqual(h.player.state, .loading)
        XCTAssertFalse(h.progressStack.isHidden)
        h.controls[0].finish()
        try await waitUntil("新请求开始播放") { h.player.state == .playing && h.progressStack.isHidden }
    }

    @MainActor
    func testRapidSwitchABAOnlyPublishesFinalReady() async throws {
        let h = try makeHarness()
        defer { h.close() }
        let appHandler = h.player.onEvent
        var ready = 0
        h.player.onEvent = { event in
            if case .ready = event { ready += 1 }
            appHandler?(event)
        }
        try await waitUntil("A 开始") { h.controls[0].starts == 1 }
        h.select(1)
        try await waitUntil("B 开始") { h.controls[1].starts == 1 }
        h.select(0)
        try await waitUntil("新 A 开始且 B 退出") { h.controls[0].starts == 2 && h.controls[1].stops >= 1 }
        h.controls[1].finish()
        XCTAssertEqual(h.player.state, .loading)
        XCTAssertEqual(ready, 0)
        h.controls[0].finish()
        try await waitUntil("最终 A 播放") { h.player.state == .playing && h.progressStack.isHidden }
        XCTAssertEqual(ready, 1)
    }

    @MainActor
    func testPauseResumeAndReplayWhilePaused() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await finishFirst(h)
        let pause = try button("暂停", in: h.controller)
        pause.sendActions(for: .touchUpInside)
        XCTAssertEqual(h.player.state, .paused)
        XCTAssertEqual(pause.accessibilityLabel, "继续")
        pause.sendActions(for: .touchUpInside)
        XCTAssertEqual(h.player.state, .playing)
        XCTAssertEqual(pause.accessibilityLabel, "暂停")
        pause.sendActions(for: .touchUpInside)
        try button("重播", in: h.controller).sendActions(for: .touchUpInside)
        try await waitUntil("暂停后重播") { h.player.state == .playing && h.progressStack.isHidden }
        XCTAssertEqual(pause.accessibilityLabel, "暂停")
        XCTAssertEqual(h.controls[0].starts, 1)
    }

    @MainActor
    func testSingleLoopFinishesAndContinueRestarts() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await finishFirst(h)
        try button("循环", in: h.controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(h.player.loops, 1)
        let entity = try await SVGAParser.shared.parse(url: h.urls[0])
        h.player.seek(toFrame: entity.frames - 1, startsPlayback: true)
        try await waitUntil("自然完成单次播放") { h.player.state == .stopped }
        XCTAssertTrue(h.progressStack.isHidden)
        let resume = try button("继续", in: h.controller)
        resume.sendActions(for: .touchUpInside)
        XCTAssertEqual(h.player.state, .playing)
        XCTAssertEqual(resume.accessibilityLabel, "暂停")
    }

    @MainActor
    func testInfiniteLoopCrossesEndWithoutFinishing() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await finishFirst(h)
        let appHandler = h.player.onEvent
        var wrapped = false
        var finished = false
        h.player.onEvent = { event in
            if case .frameChanged(let index) = event, index == 0 { wrapped = true }
            if case .finished = event { finished = true }
            appHandler?(event)
        }
        let entity = try await SVGAParser.shared.parse(url: h.urls[0])
        h.player.seek(toFrame: entity.frames - 1, startsPlayback: true)
        try await waitUntil("循环跨过末帧") { wrapped }
        XCTAssertFalse(finished)
        XCTAssertEqual(h.player.state, .playing)
        XCTAssertEqual(h.player.loops, 0)
        XCTAssertTrue(try button("暂停", in: h.controller).isEnabled)
    }

    @MainActor
    func testLeavingCancelsDownloadAndReturningHasNoStaleProgress() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await waitUntil("下载至 50%") { h.progress.progress > 0 }
        h.controller.beginAppearanceTransition(false, animated: false)
        h.controller.endAppearanceTransition()
        try await waitUntil("底层下载停止") { h.controls[0].stops >= 1 }
        XCTAssertEqual(h.player.state, .idle)
        h.controls[0].finish()
        h.controller.beginAppearanceTransition(true, animated: false)
        h.controller.endAppearanceTransition()
        capture("离开后返回页面", harness: h)
        print("STATE_AUDIT return player=\(h.player.state) progressHidden=\(h.progressStack.isHidden) starts=\(h.controls[0].starts)")
        XCTAssertTrue(h.progressStack.isHidden, "没有进行中的下载时不能显示旧下载进度")
        XCTAssertFalse(try button("暂停", in: h.controller).isEnabled)
        XCTAssertTrue(allViews(h.controller.view).compactMap { ($0 as? UILabel)?.text }.contains("播放已停止\n点击重播继续"))
        try button("重播", in: h.controller).sendActions(for: .touchUpInside)
        try await waitUntil("返回后重新下载") { h.controls[0].starts == 2 }
        h.controls[0].finish()
        try await waitUntil("返回后重播成功") { h.player.state == .playing && h.progressStack.isHidden }
        XCTAssertTrue(try button("暂停", in: h.controller).isEnabled)
    }

    @MainActor
    func testLeavingDuringPlaybackRequiresReplayAndReusesCache() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await finishFirst(h)
        h.controller.beginAppearanceTransition(false, animated: false)
        h.controller.endAppearanceTransition()
        h.controller.beginAppearanceTransition(true, animated: false)
        h.controller.endAppearanceTransition()
        XCTAssertEqual(h.player.state, .stopped)
        XCTAssertTrue(h.progressStack.isHidden)
        let pause = try button("暂停", in: h.controller)
        XCTAssertFalse(pause.isEnabled)
        pause.sendActions(for: .touchUpInside)
        XCTAssertEqual(h.player.state, .stopped)
        XCTAssertTrue(allViews(h.controller.view).compactMap { ($0 as? UILabel)?.text }.contains("播放已停止\n点击重播继续"))
        try button("重播", in: h.controller).sendActions(for: .touchUpInside)
        try await waitUntil("返回后从缓存重播") { h.player.state == .playing && h.progressStack.isHidden }
        XCTAssertEqual(h.controls[0].starts, 1)
        XCTAssertTrue(pause.isEnabled)
    }

    @MainActor
    func testEmptyCatalogueDisablesControls() throws {
        let controller = ViewController(giftEffectsLoader: { [] })
        controller.loadViewIfNeeded()
        defer { find(SVGAView.self, in: controller.view)?.stop() }
        XCTAssertTrue(allViews(controller.view).compactMap { ($0 as? UILabel)?.text }.contains("JSON 中没有礼物资源"))
        for name in ["重播", "暂停", "循环"] { XCTAssertFalse(try button(name, in: controller).isEnabled) }
        XCTAssertFalse(try XCTUnwrap(find(UISearchTextField.self, in: controller.view)).isEnabled)
    }

    @MainActor
    func testCatalogueFailureDisablesControls() throws {
        let controller = ViewController(giftEffectsLoader: { throw URLError(.cannotDecodeContentData) })
        controller.loadViewIfNeeded()
        defer { find(SVGAView.self, in: controller.view)?.stop() }
        XCTAssertTrue(allViews(controller.view).compactMap { ($0 as? UILabel)?.text }.contains { $0.hasPrefix("无法读取 gift_effects_svga.json") })
        for name in ["重播", "暂停", "循环"] { XCTAssertFalse(try button(name, in: controller).isEnabled) }
    }

    @MainActor
    func testNoSearchResultsDoesNotInterruptPlayback() async throws {
        let h = try makeHarness()
        defer { h.close() }
        try await finishFirst(h)
        let search = try XCTUnwrap(find(UISearchTextField.self, in: h.controller.view))
        search.text = "没有这个礼物的唯一查询"
        search.sendActions(for: .editingChanged)
        XCTAssertEqual(h.collection.numberOfItems(inSection: 0), 0)
        XCTAssertEqual(h.player.state, .playing)
        search.text = ""
        search.sendActions(for: .editingChanged)
        XCTAssertEqual(h.collection.numberOfItems(inSection: 0), 2)
        XCTAssertEqual(h.player.state, .playing)
    }

    @MainActor
    private func finishFirst(_ h: DownloadProgressHarness) async throws {
        try await waitUntil("第一份资源开始") { h.controls[0].starts == 1 }
        h.controls[0].finish()
        try await waitUntil("第一份资源播放") { h.player.state == .playing && h.progressStack.isHidden }
    }

    @MainActor
    private func allViews(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }

    @MainActor
    private func button(_ title: String, in controller: ViewController) throws -> UIButton {
        try XCTUnwrap(allViews(controller.view).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == title })
    }

    @MainActor
    private func capture(_ title: String, harness: DownloadProgressHarness) {
        harness.controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: harness.controller.view.bounds).image { context in
            harness.controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待超时：\(description)")
        throw NSError(domain: "DownloadProgressTests", code: 1)
    }

    @MainActor
    private func makeHarness() throws -> DownloadProgressHarness {
        let bundle = Bundle(for: ViewController.self)
        let data = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "banner", withExtension: "svga")))
        let controls = [ProgressURLProtocol.Control(data: data), ProgressURLProtocol.Control(data: data)]
        let urls = controls.map { ProgressURLProtocol.install($0) }
        let previousProtocols = SVGAURLSessionTestHooks.protocolClasses
        SVGAURLSessionTestHooks.protocolClasses = [ProgressURLProtocol.self] + (previousProtocols ?? [])
        let effects = [GiftEffect(name: "旧礼物", url: urls[0]), GiftEffect(name: "新礼物：下载至 50%", url: urls[1])]
        let controller = ViewController(giftEffectsLoader: { effects })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let player = try XCTUnwrap(find(SVGAView.self, in: controller.view))
        let progress = try XCTUnwrap(find(UIProgressView.self, in: controller.view))
        let stack = try XCTUnwrap(progress.superview as? UIStackView)
        let collection = try XCTUnwrap(find(UICollectionView.self, in: controller.view))
        return DownloadProgressHarness(controller: controller, player: player, progress: progress,
                                       progressStack: stack, collection: collection, controls: controls,
                                       urls: urls, previousProtocols: previousProtocols)
    }

    @MainActor
    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let view = root as? T { return view }
        return root.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}

@MainActor
private struct DownloadProgressHarness {
    let controller: ViewController
    let player: SVGAView
    let progress: UIProgressView
    let progressStack: UIStackView
    let collection: UICollectionView
    let controls: [ProgressURLProtocol.Control]
    let urls: [URL]
    let previousProtocols: [AnyClass]?

    func select(_ index: Int) {
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: index, section: 0))
    }

    func close() {
        player.onEvent = nil
        player.stop()
        SVGAURLSessionTestHooks.protocolClasses = previousProtocols
        urls.forEach { ProgressURLProtocol.remove($0) }
    }
}

@MainActor
private final class DownloadProgressFrameClock: NSObject {
    private var link: CADisplayLink?
    private(set) var ticks = 0
    override init() {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick() { ticks += 1; if ticks >= 12 { stop() } }
    func stop() { link?.invalidate(); link = nil }
}

/// 每个测试 URL 独立持有响应；只发送一半数据，直至测试显式放行。
private final class ProgressURLProtocol: URLProtocol, @unchecked Sendable {
    final class Control: @unchecked Sendable {
        private let queue = DispatchQueue(label: "svga.example.progress-test")
        private let data: Data
        private var instance: ProgressURLProtocol?
        private var count = 0
        private var stopCount = 0
        var stops: Int { queue.sync { stopCount } }
        var starts: Int { queue.sync { count } }
        init(data: Data) { self.data = data }
        func begin(_ instance: ProgressURLProtocol) {
            queue.sync {
                self.instance = instance
                count += 1
                let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Length": "\(data.count)"])!
                instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
                instance.client?.urlProtocol(instance, didLoad: data.prefix(data.count / 2))
            }
        }
        func finish() {
            queue.async {
                guard let instance = self.instance else { return }
                self.instance = nil
                instance.client?.urlProtocol(instance, didLoad: self.data.suffix(self.data.count - self.data.count / 2))
                instance.client?.urlProtocolDidFinishLoading(instance)
            }
        }
        func fail() {
            queue.async {
                guard let instance = self.instance else { return }
                self.instance = nil
                instance.client?.urlProtocol(instance, didFailWithError: URLError(.timedOut))
            }
        }
        func stop() { queue.sync { stopCount += 1; instance = nil } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var controls: [URL: Control] = [:]
    static func install(_ control: Control) -> URL {
        let url = URL(string: "https://example-progress.test/\(UUID().uuidString).svga")!
        lock.lock(); defer { lock.unlock() }
        controls[url] = control
        return url
    }
    static func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        controls[url] = nil
    }
    private var control: Control? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return request.url.flatMap { Self.controls[$0] }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example-progress.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { control?.begin(self) }
    override func stopLoading() { control?.stop() }
}
