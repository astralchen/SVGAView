import UIKit

/// 无视图预下载 SVGA 文件时使用的进度回调。
///
/// 回调参数位于 `0.0...1.0` 范围内，不保证在主 Actor 执行。下载进度不包含
/// 解压、解析和缓存提交；需要资源就绪时，应等待预加载方法返回。
/// 缓存命中及本地来源不触发下载进度回调。
public typealias SVGAViewPreloadProgressHandler = @Sendable (_ progress: Double) -> Void

// MARK: - 动态内容配置

/// 播放 SVGA 动画时应用的动态内容配置。
///
/// 使用 `SVGADynamicContent` 在动画加载完成前配置需要替换或隐藏的
/// sprite。每个 key 对应 SVGA 文件中的 sprite `imageKey`，也可以使用
/// 不带文件扩展名的 key。
///
/// ```swift
/// var content = SVGADynamicContent()
/// content.setImage(avatarImage, forKey: "avatar")
/// content.setAttributedText(nickname, forKey: "username")
/// content.setHidden(true, forKey: "badge")
/// playerView.play(named: "gift", dynamicContent: content)
/// ```
public struct SVGADynamicContent {

    struct Item {
        var image: UIImage?
        var text: NSAttributedString?
        var drawingBlock: SVGADynamicDrawingHandler?
        var hidden: Bool?

        init(image: UIImage? = nil,
             text: NSAttributedString? = nil,
             drawingBlock: SVGADynamicDrawingHandler? = nil,
             hidden: Bool? = nil) {
            self.image = image
            self.text = text
            self.drawingBlock = drawingBlock
            self.hidden = hidden
        }
    }

    var items: [String: Item] = [:]

    /// 创建空的动态内容配置。
    public init() {}

    /// 设置指定 sprite 的替换图片。
    ///
    /// - Parameters:
    ///   - image: 要显示的图片。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public mutating func setImage(_ image: UIImage, forKey key: String) {
        items[key, default: Item()].image = image
    }

    /// 设置指定 sprite 上叠加显示的富文本。
    ///
    /// - Parameters:
    ///   - text: 要叠加显示的富文本。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public mutating func setAttributedText(_ text: NSAttributedString, forKey key: String) {
        items[key, default: Item()].text = text
    }

    /// 设置指定 sprite 的自定义绘制回调。
    ///
    /// 回调会在 sprite 所属 layer 完成当前帧布局后调用。
    ///
    /// - Parameters:
    ///   - block: 自定义绘制回调。传入 `nil` 时不设置回调。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public mutating func setDrawingBlock(
        _ block: (@MainActor @Sendable (CALayer, Int) -> Void)?,
        forKey key: String
    ) {
        items[key, default: Item()].drawingBlock = block
    }

    /// 设置指定 sprite 的隐藏状态。
    ///
    /// - Parameters:
    ///   - hidden: `true` 表示隐藏该 sprite，`false` 表示显示。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public mutating func setHidden(_ hidden: Bool, forKey key: String) {
        items[key, default: Item()].hidden = hidden
    }
}

// MARK: - SVGAView

/// SVGA 播放视图的当前状态。
public enum SVGAViewState: Equatable, Sendable {
    /// 播放器处于空闲状态。
    case idle
    /// 播放器正在加载动画数据。
    case loading
    /// 动画数据已加载完成，可以开始播放。
    case ready
    /// 播放器正在播放动画。
    case playing
    /// 播放器已暂停播放。
    case paused
    /// 播放器已停止播放。
    case stopped
    /// 播放器加载或播放失败。
    case failed(SVGAViewError)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// `SVGAView` 抛出或回调的错误类型。
public enum SVGAViewError: Error, Equatable, LocalizedError, Sendable {
    /// URL 缺失或无法解析。
    case invalidURL
    /// URL scheme 不受支持。
    case unsupportedURLScheme(String?)
    /// 在指定 bundle 中找不到资源。
    case resourceNotFound(String)
    /// SVGA 压缩包中缺少 `movie.binary` 或 `movie.spec`。
    case missingMovieFile
    /// SVGA JSON 数据格式无效。
    case invalidJSON
    /// 下载文件超过 `SVGAParser` 配置的大小限制。
    case fileTooLarge
    /// 下载失败，保留原始网络错误的错误码和附加信息。
    case network(URLError)
    /// 视图状态或事件表示加载已取消；异步 `load` 和 `preload` 向调用方抛出 `CancellationError`。
    case cancelled
    /// 底层错误的描述。
    case underlying(String)

    /// 错误的本地化说明。
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid SVGA URL."
        case .unsupportedURLScheme(let scheme):
            return "Unsupported SVGA URL scheme: \(scheme ?? "nil")."
        case .resourceNotFound(let name):
            return "SVGA resource not found: \(name)."
        case .missingMovieFile:
            return "SVGA archive is missing movie.binary or movie.spec."
        case .invalidJSON:
            return "SVGA JSON payload is invalid."
        case .fileTooLarge:
            return "SVGA file is larger than the configured download limit."
        case .network(let error):
            return error.localizedDescription
        case .cancelled:
            return "SVGA loading was cancelled."
        case .underlying(let message):
            return message
        }
    }
}

/// `SVGAView` 向外派发的播放和加载事件。
public enum SVGAViewEvent: Equatable, Sendable {
    /// 播放器状态已变化。
    case stateChanged(SVGAViewState)
    /// 动画数据加载完成，播放器已进入 ready 状态。
    case ready
    /// 动画播放完成。
    ///
    /// 只有动画达到 `loops` 指定的次数后才会触发；无限循环不会触发该事件。
    case finished
    /// 当前帧已变化。
    case frameChanged(Int)
    /// 播放进度已变化，范围为 `0.0...1.0`。
    case percentageChanged(CGFloat)
    /// 网络下载进度已变化，范围为 `0.0...1.0`。缓存命中及本地来源不发送此事件。
    case downloadProgress(Double)
    /// 动画加载失败。
    case loadFailed(SVGAViewError)
}

/// `SVGAView` 可加载的动画数据来源。
public enum SVGAViewSource: CustomDebugStringConvertible, Sendable {
    /// Bundle 中的 SVGA 资源名。
    case named(String, bundle: Bundle? = nil)
    /// HTTP 或 HTTPS 资源 URL。
    case remoteURL(URL)
    /// 自定义网络请求。
    case request(URLRequest)
    /// 本地文件 URL。
    case fileURL(URL)
    /// 内存中的 SVGA 数据。
    case data(Data, cacheKey: String)

    /// 适合调试输出的源描述。
    public var debugDescription: String {
        switch self {
        case .named(let name, _):
            return "named(\(name))"
        case .remoteURL(let url):
            return "remoteURL(\(url.absoluteString))"
        case .request(let request):
            return "request(\(request.url?.absoluteString ?? "nil"))"
        case .fileURL(let url):
            return "fileURL(\(url.path))"
        case .data(_, let cacheKey):
            return "data(cacheKey: \(cacheKey))"
        }
    }
}

/// 指定来源的 SVGA 缓存状态。
public enum SVGACacheStatus: Equatable, Sendable {
    /// 已有可复用的本地缓存。
    case cached(localPath: String)
    /// 正在下载同一个远程资源，进度可能尚未产生。
    case downloading(progress: Double?)
    /// 没有可复用缓存，也没有正在进行的下载。
    case missing
}

private extension SVGAViewSource {
    var usesLocalResourceFrameSize: Bool {
        switch self {
        case .named, .fileURL:
            return true
        case .remoteURL, .request, .data:
            return false
        }
    }
}

/// 加载和播放 SVGA 动画的视图。
///
/// `SVGAView` 封装了动画解析、逐帧渲染、音频同步和动态内容替换。
/// 可以从 bundle 资源、网络 URL、本地文件 URL、`URLRequest` 或 `Data` 加载
/// `.svga` 动画。
///
/// ```swift
/// let playerView = SVGAView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
/// playerView.contentMode = .scaleAspectFit
/// view.addSubview(playerView)
/// playerView.play(named: "animation")
/// ```
///
/// 使用统一事件回调监听播放事件：
///
/// ```swift
/// playerView.onEvent = { event in
///     switch event {
///     case .finished:
///         print("animation finished")
///     case .loadFailed(let error):
///         print("load failed: \(error)")
///     default:
///         break
///     }
/// }
/// ```
///
/// 使用动态内容替换动画中的 sprite：
///
/// ```swift
/// var content = SVGADynamicContent()
/// content.setImage(avatar, forKey: "avatar")
/// playerView.play(named: "gift", dynamicContent: content)
/// ```
///
/// 从网络加载：
///
/// ```swift
/// playerView.play(remoteURL: URL(string: "https://example.com/anim.svga")!)
/// ```
///
/// 在 Interface Builder 中，可以设置 `resourcePath` 为资源名、HTTP(S) URL、
/// file URL 或本地绝对路径，并通过 `autoPlay` 控制是否自动播放。
@MainActor
open class SVGAView: UIView {

    // MARK: - 内部播放状态

    private let engine = SVGAPlaybackEngine()
    private var loadTask: Task<Void, Error>?
    /// 当前加载身份；异步恢复及同步用户回调返回后重新核对，阻止旧请求更新视图。
    private var loadSequence: Int = 0
    private var resourcePathLoadTask: Task<Void, Never>?
    private var isEngineConfigured = false
    private var isPerformingInspectableResourcePathLoad = false
    private var sizesFrameToNextLocalResourcePathLoad = false

    // MARK: - 公开属性

    /// 动画重复播放的次数。
    ///
    /// 值为 `0` 时无限循环。默认值为 `0`。
    public var loops: Int {
        get { engine.loops }
        set { engine.loops = newValue }
    }

    /// 一个布尔值，指示停止动画后是否清除当前画面。
    ///
    /// 默认值为 `true`。
    public var clearsAfterStop: Bool {
        get { engine.clearsAfterStop }
        set { engine.clearsAfterStop = newValue }
    }

    /// 动画结束后保留的画面。
    ///
    /// 仅当 `clearsAfterStop` 为 `false` 时生效。
    public var fillMode: SVGAFillMode {
        get { engine.fillMode }
        set { engine.fillMode = newValue }
    }

    /// 驱动动画的 display link 所使用的 run loop 模式。
    ///
    /// 默认值为 `.common`。
    public var mainRunLoopMode: RunLoop.Mode {
        get { engine.mainRunLoopMode }
        set { engine.mainRunLoopMode = newValue }
    }

    /// 一个布尔值，指示 `resourcePath` 加载完成后是否自动开始播放。
    ///
    /// `play` 方法始终会开始播放，`load` 方法使用 `startsPlayback` 显式控制。
    /// 默认值为 `true`。
    @IBInspectable public var autoPlay: Bool = true

    /// 播放器当前状态。
    ///
    /// 值变化时会同步发送 `.stateChanged` 事件；事件回调可能使当前加载失效。
    public private(set) var state: SVGAViewState = .idle {
        didSet {
            guard oldValue != state else { return }
            emit(.stateChanged(state))
        }
    }

    // MARK: - 事件

    /// 播放器事件回调。
    ///
    /// 回调在主 Actor 同步执行。高频事件包括 `.frameChanged`、
    /// `.percentageChanged` 和 `.downloadProgress`。
    ///
    /// 状态变化事件先于相应的 `.ready`、`.loadFailed` 或 `.finished` 事件发送。
    /// 回调中可以取消、清空或替换加载；后续加载结果通知及自动播放会重新检查
    /// 请求身份，已失效请求不会覆盖新请求的状态。
    public var onEvent: ((SVGAViewEvent) -> Void)?

    // MARK: - Interface Builder 资源加载

    /// Interface Builder 使用的动画资源路径。
    ///
    /// 该值可以是 bundle 资源名、HTTP(S) URL、file URL 或本地绝对路径。
    /// 设置后会自动开始加载，并根据 `autoPlay` 决定是否播放。
    @IBInspectable public var resourcePath: String? {
        didSet {
            if oldValue != nil {
                sizesFrameToNextLocalResourcePathLoad = false
            }
            scheduleInspectableResourcePathLoad()
        }
    }

    // MARK: - 初始化

    /// 使用指定 frame 创建播放器视图。
    ///
    /// - Parameter frame: 视图的初始 frame。
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupEngine()
    }

    /// 使用资源路径创建播放器视图，并在本地资源加载完成后使用资源尺寸作为初始 frame size。
    ///
    /// - Parameter resourcePath: bundle 资源名、file URL、本地绝对路径或 HTTP(S) URL。
    public convenience init(resourcePath: String) {
        self.init(frame: .zero)
        let path = resourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        sizesFrameToNextLocalResourcePathLoad = !path.isEmpty
        self.resourcePath = resourcePath
        scheduleInspectableResourcePathLoad()
    }

    /// 使用 bundle 中的 SVGA 资源创建播放器视图。
    ///
    /// 加载完成后会根据 `autoPlay` 决定是否播放；如果初始 frame size 为 `.zero`，
    /// 会使用资源的原始尺寸作为初始 frame size。
    ///
    /// - Parameters:
    ///   - name: 资源名（不含 `.svga` 扩展名）。
    ///   - bundle: 资源所在的 bundle。传入 `nil` 时使用 `Bundle.main`。
    public convenience init(named name: String, in bundle: Bundle? = nil) {
        self.init(frame: .zero)
        startLoadTask(
            source: .named(name, bundle: bundle),
            dynamicContent: nil,
            startsPlaybackAfterLoad: autoPlay,
            sizesFrameToContentAfterLoad: true
        )
    }

    /// 使用本地文件 URL 创建播放器视图。
    ///
    /// 加载完成后会根据 `autoPlay` 决定是否播放；如果初始 frame size 为 `.zero`，
    /// 会使用资源的原始尺寸作为初始 frame size。
    ///
    /// - Parameter fileURL: 指向 SVGA 文件的本地文件 URL。
    public convenience init(fileURL: URL) {
        self.init(frame: .zero)
        startLoadTask(
            source: .fileURL(fileURL),
            dynamicContent: nil,
            startsPlaybackAfterLoad: autoPlay,
            sizesFrameToContentAfterLoad: true
        )
    }

    /// 使用 HTTP 或 HTTPS URL 创建播放器视图。
    ///
    /// 加载完成后会根据 `autoPlay` 决定是否播放。
    ///
    /// - Parameter remoteURL: SVGA 文件的 HTTP(S) URL。
    public convenience init(remoteURL: URL) {
        self.init(frame: .zero)
        startLoadTask(
            source: .remoteURL(remoteURL),
            dynamicContent: nil,
            startsPlaybackAfterLoad: autoPlay
        )
    }

    /// 从 storyboard 或 nib 反序列化播放器视图。
    ///
    /// - Parameter coder: 用于反序列化视图的 coder。
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupEngine()
    }

    private func setupEngine() {
        engine.onRenderLayerChanged = { [weak self] newLayer in
            guard let self else { return }
            if let l = newLayer {
                self.layer.addSublayer(l)
                self.engine.resize(bounds: self.bounds.size, contentMode: self.contentMode)
            }
        }
        engine.delegate = self
        isEngineConfigured = true
        scheduleInspectableResourcePathLoad()
    }

    private func emit(_ event: SVGAViewEvent) {
        onEvent?(event)
    }

    private func scheduleInspectableResourcePathLoad() {
        resourcePathLoadTask?.cancel()
        guard isEngineConfigured else { return }
        guard let path = resourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            resourcePathLoadTask = nil
            return
        }

        resourcePathLoadTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            guard self.resourcePath?.trimmingCharacters(in: .whitespacesAndNewlines) == path else { return }
            self.loadInspectableResourcePath(path)
            self.resourcePathLoadTask = nil
        }
    }

    private func loadInspectableResourcePath(_ path: String) {
        isPerformingInspectableResourcePathLoad = true
        defer { isPerformingInspectableResourcePathLoad = false }
        let source = inspectableResourceSource(for: path)
        let sizesFrameToContent = sizesFrameToNextLocalResourcePathLoad && source.usesLocalResourceFrameSize
        sizesFrameToNextLocalResourcePathLoad = false
        startLoadTask(
            source: source,
            dynamicContent: nil,
            startsPlaybackAfterLoad: autoPlay,
            sizesFrameToContentAfterLoad: sizesFrameToContent
        )
    }

    private func inspectableResourceSource(for path: String) -> SVGAViewSource {
        if let url = URL(string: path),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return .remoteURL(url)
            case "file":
                return .fileURL(url)
            default:
                return .remoteURL(url)
            }
        } else if path.hasPrefix("/") {
            return .fileURL(URL(fileURLWithPath: path))
        } else {
            return .named(path, bundle: nil)
        }
    }

    // MARK: - 视图生命周期

    open override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            resourcePathLoadTask?.cancel()
            resourcePathLoadTask = nil
            cancelLoading(resetState: true)
            engine.stop()
            state = .stopped
        }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        engine.resize(bounds: bounds.size, contentMode: contentMode)
    }

    open override var intrinsicContentSize: CGSize {
        engine.contentSize ?? super.intrinsicContentSize
    }

    open override func sizeThatFits(_ size: CGSize) -> CGSize {
        engine.contentSize ?? super.sizeThatFits(size)
    }

    // MARK: - 预加载

    /// 无需创建视图，预先加载并缓存指定来源的 SVGA 数据。
    ///
    /// 此方法完成所需的下载、解压、解析和缓存，后续使用相同来源加载或播放时
    /// 可复用结果。共享加载的每次调用拥有独立订阅；取消一个调用不会影响其他
    /// 订阅者。最后一个订阅取消后，等待底层工作退出及暂存清理，再结束异步等待。
    ///
    /// 同步解压和解析在阶段边界检查取消，不保证立即中断。已经确定的成功结果
    /// 不被迟到取消改写。下载进度达到 `1` 不代表解析及缓存发布完成，应等待方法返回。
    ///
    /// 异步取消抛出 `CancellationError`；`SVGAViewError.cancelled` 仅用于视图状态和事件。
    ///
    /// ```swift
    /// do {
    ///     try await SVGAView.preload(remoteURL: url)
    /// } catch is CancellationError {
    ///     // 当前调用已取消。
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - source: 动画数据来源。
    ///   - progressHandler: 可选的下载进度回调，取值范围为 `0...1`，不保证在主 Actor 执行。仅在实际下载时回调；缓存命中及本地来源不回调。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    @concurrent public nonisolated static func preload(
        _ source: SVGAViewSource,
        progressHandler: SVGAViewPreloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        do {
            _ = try await fetchEntity(for: source, progressHandler: progressHandler)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw viewError(from: error)
        }
    }

    /// 无需创建视图，预先加载并缓存 bundle 中的 SVGA 数据。
    ///
    /// 共享加载、取消和缓存行为与 `preload(_:progressHandler:)` 相同。
    ///
    /// - Parameters:
    ///   - name: 资源名，可省略 `.svga` 扩展名。
    ///   - bundle: 资源所在的 bundle。默认值为 `nil`，使用 `Bundle.main`。
    ///   - progressHandler: 可选的下载进度回调，取值范围为 `0...1`，不保证在主 Actor 执行。仅在实际下载时回调；缓存命中及本地来源不回调。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    @concurrent public nonisolated static func preload(
        named name: String,
        in bundle: Bundle? = nil,
        progressHandler: SVGAViewPreloadProgressHandler? = nil
    ) async throws {
        try await preload(.named(name, bundle: bundle), progressHandler: progressHandler)
    }

    /// 无需创建视图，预先加载并缓存 HTTP 或 HTTPS URL 指向的 SVGA 数据。
    ///
    /// 共享加载、取消和缓存行为与 `preload(_:progressHandler:)` 相同。
    ///
    /// - Parameters:
    ///   - url: SVGA 文件的 HTTP 或 HTTPS URL。
    ///   - progressHandler: 可选的下载进度回调，取值范围为 `0...1`，不保证在主 Actor 执行。仅在实际下载时回调；缓存命中及本地来源不回调。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    @concurrent public nonisolated static func preload(
        remoteURL url: URL,
        progressHandler: SVGAViewPreloadProgressHandler? = nil
    ) async throws {
        try await preload(.remoteURL(url), progressHandler: progressHandler)
    }

    /// 无需创建视图，预先加载并缓存自定义请求对应的 SVGA 数据。
    ///
    /// 共享加载、取消和缓存行为与 `preload(_:progressHandler:)` 相同。
    ///
    /// - Parameters:
    ///   - request: 用于下载 SVGA 文件的请求，URL 必须使用 HTTP 或 HTTPS。
    ///   - progressHandler: 可选的下载进度回调，取值范围为 `0...1`，不保证在主 Actor 执行。仅在实际下载时回调；缓存命中及本地来源不回调。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    @concurrent public nonisolated static func preload(
        request: URLRequest,
        progressHandler: SVGAViewPreloadProgressHandler? = nil
    ) async throws {
        try await preload(.request(request), progressHandler: progressHandler)
    }

    /// 无需创建视图，预先加载并缓存本地文件 URL 指向的 SVGA 数据。
    ///
    /// 共享加载、取消和缓存行为与 `preload(_:progressHandler:)` 相同。
    ///
    /// - Parameters:
    ///   - fileURL: 指向 SVGA 文件的本地文件 URL。
    ///   - progressHandler: 可选的下载进度回调，取值范围为 `0...1`，不保证在主 Actor 执行。仅在实际下载时回调；缓存命中及本地来源不回调。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    @concurrent public nonisolated static func preload(
        fileURL: URL,
        progressHandler: SVGAViewPreloadProgressHandler? = nil
    ) async throws {
        try await preload(.fileURL(fileURL), progressHandler: progressHandler)
    }

    /// 无需创建视图，预先加载并缓存内存中的 SVGA 数据。
    ///
    /// 共享加载、取消和缓存行为与 `preload(_:progressHandler:)` 相同。
    ///
    /// - Parameters:
    ///   - data: SVGA 文件数据。
    ///   - cacheKey: 用于共享解析及读写缓存的稳定键；不同资源应使用不同键。
    ///   - progressHandler: 可选的下载进度回调，取值范围为 `0...1`，不保证在主 Actor 执行。仅在实际下载时回调；缓存命中及本地来源不回调。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    @concurrent public nonisolated static func preload(
        data: Data,
        cacheKey: String,
        progressHandler: SVGAViewPreloadProgressHandler? = nil
    ) async throws {
        try await preload(.data(data, cacheKey: cacheKey), progressHandler: progressHandler)
    }

    // MARK: - 缓存查询

    /// 查询指定来源的缓存状态。
    ///
    /// 已完成缓存会返回 `.cached(localPath:)`；远程资源正在下载时会返回
    /// `.downloading(progress:)`；其余情况返回 `.missing`。
    ///
    /// - Parameter source: 动画数据来源。
    /// - Returns: 指定来源的缓存状态。
    @concurrent public nonisolated static func cacheStatus(_ source: SVGAViewSource) async -> SVGACacheStatus {
        switch source {
        case .named(let name, let bundle):
            return await SVGAParser.shared.cacheStatus(named: name, in: bundle)
        case .remoteURL(let url):
            guard (try? validateRemoteURL(url)) != nil else { return .missing }
            return await SVGAParser.shared.cacheStatus(url: url)
        case .request(let request):
            guard let url = request.url,
                  (try? validateRemoteURL(url)) != nil else {
                return .missing
            }
            return await SVGAParser.shared.cacheStatus(request: request)
        case .fileURL(let url):
            guard url.isFileURL else { return .missing }
            return await SVGAParser.shared.cacheStatus(fileURL: url)
        case .data(_, let cacheKey):
            return await SVGAParser.shared.cacheStatus(dataCacheKey: cacheKey)
        }
    }

    /// 查询 bundle 中 SVGA 资源的缓存状态。
    ///
    /// 此方法不触发下载；进行中的状态仅为查询时快照。
    ///
    /// - Parameters:
    ///   - name: 资源名，可省略 `.svga` 扩展名。
    ///   - bundle: 资源所在的 bundle。默认值为 `nil`，使用 `Bundle.main`。
    /// - Returns: 当前缓存状态；来源不可用或尚未缓存时为 `.missing`。
    @concurrent public nonisolated static func cacheStatus(
        named name: String,
        in bundle: Bundle? = nil
    ) async -> SVGACacheStatus {
        await cacheStatus(.named(name, bundle: bundle))
    }

    /// 查询 HTTP 或 HTTPS SVGA 文件的缓存状态。
    ///
    /// 此方法不触发下载；进行中的状态仅为查询时快照。
    ///
    /// - Parameters:
    ///   - url: 资源的 HTTP 或 HTTPS URL。
    /// - Returns: 当前缓存状态；来源不可用或尚未缓存时为 `.missing`。
    @concurrent public nonisolated static func cacheStatus(remoteURL url: URL) async -> SVGACacheStatus {
        await cacheStatus(.remoteURL(url))
    }

    /// 查询自定义请求对应 SVGA 文件的缓存状态。
    ///
    /// 此方法不触发下载；进行中的状态仅为查询时快照。
    ///
    /// - Parameters:
    ///   - request: 用于定位远程资源的请求。
    /// - Returns: 当前缓存状态；来源不可用或尚未缓存时为 `.missing`。
    @concurrent public nonisolated static func cacheStatus(request: URLRequest) async -> SVGACacheStatus {
        await cacheStatus(.request(request))
    }

    /// 查询本地文件 URL 指向 SVGA 文件的缓存状态。
    ///
    /// 此方法不触发下载；进行中的状态仅为查询时快照。
    ///
    /// - Parameters:
    ///   - fileURL: 指向 SVGA 文件的本地文件 URL。
    /// - Returns: 当前缓存状态；来源不可用或尚未缓存时为 `.missing`。
    @concurrent public nonisolated static func cacheStatus(fileURL: URL) async -> SVGACacheStatus {
        await cacheStatus(.fileURL(fileURL))
    }

    /// 查询内存中 SVGA 数据指定 cache key 对应的缓存状态。
    ///
    /// 此方法不触发下载；进行中的状态仅为查询时快照。
    ///
    /// - Parameters:
    ///   - data: SVGA 数据；此重载使用指定的缓存键进行查询。
    ///   - cacheKey: 加载或预加载时使用的稳定缓存键。
    /// - Returns: 当前缓存状态；来源不可用或尚未缓存时为 `.missing`。
    @concurrent public nonisolated static func cacheStatus(data: Data, cacheKey: String) async -> SVGACacheStatus {
        await cacheStatus(.data(data, cacheKey: cacheKey))
    }

    /// 查询调用方指定 data cache key 对应的缓存状态。
    ///
    /// 此方法不触发下载；进行中的状态仅为查询时快照。
    ///
    /// - Parameters:
    ///   - cacheKey: 加载或预加载内存数据时使用的稳定缓存键。
    /// - Returns: 当前缓存状态；来源不可用或尚未缓存时为 `.missing`。
    @concurrent public nonisolated static func cacheStatus(dataCacheKey cacheKey: String) async -> SVGACacheStatus {
        await SVGAParser.shared.cacheStatus(dataCacheKey: cacheKey)
    }

    // MARK: - 播放

    /// 加载指定来源的 SVGA 文件并开始播放。
    ///
    /// `play` 的语义始终是加载并播放，不受 `autoPlay` 影响。`autoPlay` 仅用于
    /// `resourcePath` 和 Interface Builder 加载。
    ///
    /// - Parameters:
    ///   - source: 动画数据来源。
    ///   - dynamicContent: 可选的动态内容配置。
    public func play(_ source: SVGAViewSource, dynamicContent: SVGADynamicContent? = nil) {
        startLoadTask(source: source, dynamicContent: dynamicContent, startsPlaybackAfterLoad: true)
    }

    /// 加载指定来源的 SVGA 文件，配置动态内容后开始播放。
    ///
    /// - Parameters:
    ///   - source: 动画数据来源。
    ///   - configureDynamicContent: 动态内容配置闭包。
    public func play(
        _ source: SVGAViewSource,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) {
        play(source, dynamicContent: makeDynamicContent(configureDynamicContent))
    }

    /// 从 bundle 加载 SVGA 资源并开始播放。
    ///
    /// - Parameters:
    ///   - name: 资源名（不含 `.svga` 扩展名）。
    ///   - bundle: 资源所在的 bundle。传入 `nil` 时使用 `Bundle.main`。
    ///   - dynamicContent: 可选的动态内容配置。
    public func play(named name: String, in bundle: Bundle? = nil, dynamicContent: SVGADynamicContent? = nil) {
        play(.named(name, bundle: bundle), dynamicContent: dynamicContent)
    }

    /// 从 bundle 加载 SVGA 资源，配置动态内容后开始播放。
    public func play(
        named name: String,
        in bundle: Bundle? = nil,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) {
        play(.named(name, bundle: bundle), configureDynamicContent: configureDynamicContent)
    }

    /// 从 HTTP 或 HTTPS URL 加载 SVGA 文件并开始播放。
    ///
    /// - Parameters:
    ///   - url: SVGA 文件的 HTTP(S) URL。
    ///   - dynamicContent: 可选的动态内容配置。
    public func play(remoteURL url: URL, dynamicContent: SVGADynamicContent? = nil) {
        play(.remoteURL(url), dynamicContent: dynamicContent)
    }

    /// 从 HTTP 或 HTTPS URL 加载 SVGA 文件，配置动态内容后开始播放。
    public func play(
        remoteURL url: URL,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) {
        play(.remoteURL(url), configureDynamicContent: configureDynamicContent)
    }

    /// 使用自定义请求加载 SVGA 文件并开始播放。
    ///
    /// - Parameters:
    ///   - request: 用于下载 SVGA 文件的请求。
    ///   - dynamicContent: 可选的动态内容配置。
    public func play(request: URLRequest, dynamicContent: SVGADynamicContent? = nil) {
        play(.request(request), dynamicContent: dynamicContent)
    }

    /// 使用自定义请求加载 SVGA 文件，配置动态内容后开始播放。
    public func play(
        request: URLRequest,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) {
        play(.request(request), configureDynamicContent: configureDynamicContent)
    }

    /// 从本地文件 URL 加载 SVGA 文件并开始播放。
    ///
    /// - Parameters:
    ///   - fileURL: 指向 SVGA 文件的本地文件 URL。
    ///   - dynamicContent: 可选的动态内容配置。
    public func play(fileURL: URL, dynamicContent: SVGADynamicContent? = nil) {
        play(.fileURL(fileURL), dynamicContent: dynamicContent)
    }

    /// 从本地文件 URL 加载 SVGA 文件，配置动态内容后开始播放。
    public func play(
        fileURL: URL,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) {
        play(.fileURL(fileURL), configureDynamicContent: configureDynamicContent)
    }

    /// 从内存数据加载 SVGA 文件并开始播放。
    ///
    /// - Parameters:
    ///   - data: SVGA 文件数据。
    ///   - cacheKey: 用于读写内存缓存和磁盘缓存的稳定 key。
    ///   - dynamicContent: 可选的动态内容配置。
    public func play(data: Data, cacheKey: String, dynamicContent: SVGADynamicContent? = nil) {
        play(.data(data, cacheKey: cacheKey), dynamicContent: dynamicContent)
    }

    /// 从内存数据加载 SVGA 文件，配置动态内容后开始播放。
    public func play(
        data: Data,
        cacheKey: String,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) {
        play(.data(data, cacheKey: cacheKey), configureDynamicContent: configureDynamicContent)
    }

    // MARK: - 加载

    /// 加载指定来源的 SVGA 数据。
    ///
    /// 默认只加载动画，不自动开始播放；`startsPlayback` 不受 `autoPlay` 影响。
    /// 新调用会替换当前加载。调用方任务取消会传递给内部加载任务，并等待其退出；
    /// `cancelLoading()`、`clear()` 或替换加载也会使当前请求失效。
    ///
    /// 共享资源的其他订阅不受取消影响；最后一个订阅取消后，异步调用等待底层
    /// 工作退出及暂存清理。仍有效的请求取消时，视图状态和事件使用 `.cancelled`，
    /// 调用方收到 `CancellationError`。已被停止或替换的旧请求不再更新视图或发送失败事件。
    ///
    /// - Parameters:
    ///   - source: 动画数据来源。
    ///   - dynamicContent: 可选的动态内容配置。默认值为 `nil`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        _ source: SVGAViewSource,
        dynamicContent: SVGADynamicContent? = nil,
        startsPlayback: Bool = false
    ) async throws {
        try Task.checkCancellation()
        let task = managedLoadTask(source: source, dynamicContent: dynamicContent,
                                   startsPlaybackAfterLoad: startsPlayback,
                                   sizesFrameToContentAfterLoad: false,
                                   reportsCancellation: true)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    /// 加载指定来源的 SVGA 数据，并在加载前配置动态内容。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - source: 动画数据来源。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    ///   - configureDynamicContent: 在加载前同步执行的动态内容配置闭包。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        _ source: SVGAViewSource,
        startsPlayback: Bool = false,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) async throws {
        try await load(
            source,
            dynamicContent: makeDynamicContent(configureDynamicContent),
            startsPlayback: startsPlayback
        )
    }

    /// 加载 bundle 中的 SVGA 数据。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - name: 资源名，可省略 `.svga` 扩展名。
    ///   - bundle: 资源所在的 bundle。默认值为 `nil`，使用 `Bundle.main`。
    ///   - dynamicContent: 可选的动态内容配置。默认值为 `nil`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        named name: String,
        in bundle: Bundle? = nil,
        dynamicContent: SVGADynamicContent? = nil,
        startsPlayback: Bool = false
    ) async throws {
        try await load(.named(name, bundle: bundle), dynamicContent: dynamicContent, startsPlayback: startsPlayback)
    }

    /// 加载 bundle 中的 SVGA 数据，并在加载前配置动态内容。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - name: 资源名，可省略 `.svga` 扩展名。
    ///   - bundle: 资源所在的 bundle。默认值为 `nil`，使用 `Bundle.main`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    ///   - configureDynamicContent: 在加载前同步执行的动态内容配置闭包。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        named name: String,
        in bundle: Bundle? = nil,
        startsPlayback: Bool = false,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) async throws {
        try await load(
            .named(name, bundle: bundle),
            startsPlayback: startsPlayback,
            configureDynamicContent: configureDynamicContent
        )
    }

    /// 加载 HTTP 或 HTTPS URL 指向的 SVGA 数据。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - url: SVGA 文件的 HTTP 或 HTTPS URL。
    ///   - dynamicContent: 可选的动态内容配置。默认值为 `nil`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        remoteURL url: URL,
        dynamicContent: SVGADynamicContent? = nil,
        startsPlayback: Bool = false
    ) async throws {
        try await load(.remoteURL(url), dynamicContent: dynamicContent, startsPlayback: startsPlayback)
    }

    /// 加载 HTTP 或 HTTPS URL 指向的 SVGA 数据，并在加载前配置动态内容。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - url: SVGA 文件的 HTTP 或 HTTPS URL。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    ///   - configureDynamicContent: 在加载前同步执行的动态内容配置闭包。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        remoteURL url: URL,
        startsPlayback: Bool = false,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) async throws {
        try await load(.remoteURL(url), startsPlayback: startsPlayback, configureDynamicContent: configureDynamicContent)
    }

    /// 加载自定义请求对应的 SVGA 数据。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - request: 用于下载 SVGA 文件的请求，URL 必须使用 HTTP 或 HTTPS。
    ///   - dynamicContent: 可选的动态内容配置。默认值为 `nil`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        request: URLRequest,
        dynamicContent: SVGADynamicContent? = nil,
        startsPlayback: Bool = false
    ) async throws {
        try await load(.request(request), dynamicContent: dynamicContent, startsPlayback: startsPlayback)
    }

    /// 加载自定义请求对应的 SVGA 数据，并在加载前配置动态内容。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - request: 用于下载 SVGA 文件的请求，URL 必须使用 HTTP 或 HTTPS。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    ///   - configureDynamicContent: 在加载前同步执行的动态内容配置闭包。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        request: URLRequest,
        startsPlayback: Bool = false,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) async throws {
        try await load(.request(request), startsPlayback: startsPlayback, configureDynamicContent: configureDynamicContent)
    }

    /// 加载本地文件 URL 指向的 SVGA 数据。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - fileURL: 指向 SVGA 文件的本地文件 URL。
    ///   - dynamicContent: 可选的动态内容配置。默认值为 `nil`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        fileURL: URL,
        dynamicContent: SVGADynamicContent? = nil,
        startsPlayback: Bool = false
    ) async throws {
        try await load(.fileURL(fileURL), dynamicContent: dynamicContent, startsPlayback: startsPlayback)
    }

    /// 加载本地文件 URL 指向的 SVGA 数据，并在加载前配置动态内容。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - fileURL: 指向 SVGA 文件的本地文件 URL。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    ///   - configureDynamicContent: 在加载前同步执行的动态内容配置闭包。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        fileURL: URL,
        startsPlayback: Bool = false,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) async throws {
        try await load(.fileURL(fileURL), startsPlayback: startsPlayback, configureDynamicContent: configureDynamicContent)
    }

    /// 加载内存中的 SVGA 数据。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - data: SVGA 文件数据。
    ///   - cacheKey: 用于共享解析及读写缓存的稳定键；不同资源应使用不同键。
    ///   - dynamicContent: 可选的动态内容配置。默认值为 `nil`。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        data: Data,
        cacheKey: String,
        dynamicContent: SVGADynamicContent? = nil,
        startsPlayback: Bool = false
    ) async throws {
        try await load(.data(data, cacheKey: cacheKey), dynamicContent: dynamicContent, startsPlayback: startsPlayback)
    }

    /// 加载内存中的 SVGA 数据，并在加载前配置动态内容。
    ///
    /// 请求替换、取消和事件行为与 `load(_:dynamicContent:startsPlayback:)` 相同。
    ///
    /// - Parameters:
    ///   - data: SVGA 文件数据。
    ///   - cacheKey: 用于共享解析及读写缓存的稳定键；不同资源应使用不同键。
    ///   - startsPlayback: 是否在加载完成后立即播放。默认值为 `false`。
    ///   - configureDynamicContent: 在加载前同步执行的动态内容配置闭包。
    /// - Throws: 取消时抛出 `CancellationError`；其他加载、解压或解析失败以 `SVGAViewError` 表达。
    public func load(
        data: Data,
        cacheKey: String,
        startsPlayback: Bool = false,
        configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) async throws {
        try await load(
            .data(data, cacheKey: cacheKey),
            startsPlayback: startsPlayback,
            configureDynamicContent: configureDynamicContent
        )
    }

    /// 请求取消当前加载，并使其后续结果失效。
    ///
    /// 本方法立即返回，不等待底层工作清理。加载中的状态会恢复为 `.idle`，
    /// 已经开始的播放不因此停止。共享资源的其他订阅者不受影响。
    public func cancelLoading() {
        cancelLoading(resetState: true)
    }

    @discardableResult
    private func cancelLoading(resetState: Bool) -> Int {
        loadSequence += 1
        let sequence = loadSequence
        let task = loadTask
        loadTask = nil
        // 先撤销句柄，取消处理器重入时不能覆盖随后登记的新任务。
        task?.cancel()
        if loadSequence == sequence, resetState, state.isLoading {
            state = .idle
        }
        return sequence
    }

    private func makeDynamicContent(
        _ configureDynamicContent: (inout SVGADynamicContent) -> Void
    ) -> SVGADynamicContent {
        var dynamicContent = SVGADynamicContent()
        configureDynamicContent(&dynamicContent)
        return dynamicContent
    }

    private func startLoadTask(
        source: SVGAViewSource,
        dynamicContent: SVGADynamicContent?,
        startsPlaybackAfterLoad: Bool
    ) {
        startLoadTask(
            source: source,
            dynamicContent: dynamicContent,
            startsPlaybackAfterLoad: startsPlaybackAfterLoad,
            sizesFrameToContentAfterLoad: false
        )
    }

    private func startLoadTask(
        source: SVGAViewSource,
        dynamicContent: SVGADynamicContent?,
        startsPlaybackAfterLoad: Bool,
        sizesFrameToContentAfterLoad: Bool
    ) {
        _ = managedLoadTask(source: source, dynamicContent: dynamicContent,
                            startsPlaybackAfterLoad: startsPlaybackAfterLoad,
                            sizesFrameToContentAfterLoad: sizesFrameToContentAfterLoad,
                            reportsCancellation: false)
    }

    /// 创建并登记当前视图唯一有效的加载任务。
    ///
    /// 直接异步加载和便捷播放共用此入口，以统一请求替换、取消和事件身份校验。
    /// `reportsCancellation` 控制仍有效请求的取消是否发送失败事件；已失效请求始终静默。
    private func managedLoadTask(
        source: SVGAViewSource, dynamicContent: SVGADynamicContent?,
        startsPlaybackAfterLoad: Bool, sizesFrameToContentAfterLoad: Bool,
        reportsCancellation: Bool
    ) -> Task<Void, Error> {
        if !isPerformingInspectableResourcePathLoad {
            resourcePathLoadTask?.cancel()
            resourcePathLoadTask = nil
        }
        let sequence = cancelLoading(resetState: false)
        guard loadSequence == sequence else {
            return Task { throw CancellationError() }
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            defer { if self.loadSequence == sequence { self.loadTask = nil } }
            do {
                try self.checkLoad(sequence)
                try await self.performLoad(source: source, dynamicContent: dynamicContent,
                                           sequence: sequence,
                                           sizesFrameToContentAfterLoad: sizesFrameToContentAfterLoad)
                try self.checkLoad(sequence)
                self.state = .ready
                // state.didSet 同步发送事件，回调可能 clear/stop 或替换加载。
                try self.checkLoad(sequence)
                self.emit(.ready)
                if startsPlaybackAfterLoad, self.loadSequence == sequence, !Task.isCancelled {
                    self.start()
                }
            } catch {
                if self.loadSequence == sequence, reportsCancellation || !(error is CancellationError) {
                    let mapped = Self.viewError(from: error)
                    // 状态通知可同步重入；只有回调返回后仍有效的请求才能继续发送失败事件。
                    self.state = .failed(mapped)
                    if self.loadSequence == sequence { self.emit(.loadFailed(mapped)) }
                }
                if error is CancellationError { throw CancellationError() }
                throw Self.viewError(from: error)
            }
        }
        loadTask = task
        // 句柄和身份必须先登记，.loading 回调中的取消才能命中本次任务。
        beginLoadingState()
        return task
    }

    /// 同时检查任务取消与请求归属；仅检查 Task 取消不足以识别同步回调中的替换。
    private func checkLoad(_ sequence: Int) throws {
        try Task.checkCancellation()
        guard loadSequence == sequence else { throw CancellationError() }
    }

    private func performLoad(
        source: SVGAViewSource,
        dynamicContent: SVGADynamicContent?,
        sequence: Int,
        sizesFrameToContentAfterLoad: Bool = false
    ) async throws {
        let progressHandler = makeProgressHandler(sequence: sequence)
        let entity = try await Self.fetchEntity(for: source, progressHandler: progressHandler)
        try checkLoad(sequence)
        engine.clearDynamicContent()
        if let content = dynamicContent { applyDynamicContent(content) }
        try checkLoad(sequence)
        if sizesFrameToContentAfterLoad { applyInitialResourceFrameSize(entity.videoSize) }
        engine.videoEntity = entity
        invalidateIntrinsicContentSize()
    }

    private func applyInitialResourceFrameSize(_ size: CGSize) {
        guard bounds.size == .zero,
              size.width > 0,
              size.height > 0
        else { return }
        var initialFrame = frame
        initialFrame.size = size
        frame = initialFrame
    }

    private nonisolated static func fetchEntity(
        for source: SVGAViewSource,
        progressHandler: SVGADownloadProgressHandler?
    ) async throws -> SVGA.VideoEntity {
        switch source {
        case .named(let name, let bundle):
            return try await SVGAParser.shared.parse(named: name, in: bundle)
        case .remoteURL(let url):
            try validateRemoteURL(url)
            return try await SVGAParser.shared.parse(url: url, progressHandler: progressHandler)
        case .request(let request):
            guard let url = request.url else {
                throw SVGAViewError.invalidURL
            }
            try validateRemoteURL(url)
            return try await SVGAParser.shared.parse(request: request, progressHandler: progressHandler)
        case .fileURL(let url):
            guard url.isFileURL else {
                throw SVGAViewError.unsupportedURLScheme(url.scheme)
            }
            return try await SVGAParser.shared.parse(fileURL: url)
        case .data(let data, let cacheKey):
            return try await SVGAParser.shared.parse(data: data, cacheKey: cacheKey)
        }
    }

    private nonisolated static func validateRemoteURL(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw SVGAViewError.unsupportedURLScheme(url.scheme)
        }
    }

    /// 将下载进度切换到主 Actor，并在实际发送前重新验证请求仍处于加载状态。
    private func makeProgressHandler(sequence: Int) -> SVGADownloadProgressHandler {
        { [weak self] progress in
            Task { @MainActor in
                guard let self, self.loadSequence == sequence,
                      self.state.isLoading, self.loadTask?.isCancelled == false else { return }
                self.emit(.downloadProgress(progress))
            }
        }
    }

    private func beginLoadingState() {
        state = .loading
    }

    private nonisolated static func viewError(from error: Error) -> SVGAViewError {
        if error is CancellationError {
            return .cancelled
        }
        if let viewError = error as? SVGAViewError {
            return viewError
        }
        if let urlError = error as? URLError {
            return .network(urlError)
        }
        if let parserError = error as? SVGAParserError {
            switch parserError {
            case .invalidURL:
                return .invalidURL
            case .resourceNotFound(let name):
                return .resourceNotFound(name)
            case .missingMovieFile:
                return .missingMovieFile
            case .invalidJSON:
                return .invalidJSON
            case .fileTooLarge:
                return .fileTooLarge
            }
        }
        return .underlying(error.localizedDescription)
    }

    private func applyDynamicContent(_ content: SVGADynamicContent) {
        for (key, item) in content.items {
            if let image = item.image {
                engine.setImage(image, forKey: key)
            }
            if let text = item.text {
                engine.setAttributedText(text, forKey: key)
            }
            if let block = item.drawingBlock {
                engine.setDrawingBlock(block, forKey: key)
            }
            if let hidden = item.hidden {
                engine.setHidden(hidden, forKey: key)
            }
        }
    }

    // MARK: - 动态内容

    /// 替换指定 sprite 的图片。
    ///
    /// 可以在加载完成后或播放过程中调用。
    ///
    /// - Parameters:
    ///   - image: 要显示的图片。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public func setImage(_ image: UIImage, forKey key: String) {
        engine.setImage(image, forKey: key)
    }

    /// 移除指定 sprite 的动态图片，并恢复 SVGA 文件中的原始图片。
    ///
    /// - Parameter key: SVGA 文件中的 sprite `imageKey`。
    public func removeImage(forKey key: String) {
        engine.removeImage(forKey: key)
    }

    /// 在指定 sprite 上叠加富文本。
    ///
    /// 可以在加载完成后或播放过程中调用。
    ///
    /// - Parameters:
    ///   - text: 要叠加显示的富文本。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public func setAttributedText(_ text: NSAttributedString, forKey key: String) {
        engine.setAttributedText(text, forKey: key)
    }

    /// 移除指定 sprite 上的动态富文本。
    ///
    /// - Parameter key: SVGA 文件中的 sprite `imageKey`。
    public func removeAttributedText(forKey key: String) {
        engine.removeAttributedText(forKey: key)
    }

    /// 设置指定 sprite 的自定义绘制回调。
    ///
    /// - Parameters:
    ///   - block: 自定义绘制回调。传入 `nil` 时移除回调。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public func setDrawingBlock(
        _ block: (@MainActor @Sendable (CALayer, Int) -> Void)?,
        forKey key: String
    ) {
        engine.setDrawingBlock(block, forKey: key)
    }

    /// 移除指定 sprite 的自定义绘制回调。
    ///
    /// - Parameter key: SVGA 文件中的 sprite `imageKey`。
    public func removeDrawingBlock(forKey key: String) {
        engine.removeDrawingBlock(forKey: key)
    }

    /// 设置指定 sprite 的隐藏状态。
    ///
    /// - Parameters:
    ///   - hidden: `true` 表示隐藏该 sprite，`false` 表示显示。
    ///   - key: SVGA 文件中的 sprite `imageKey`。
    public func setHidden(_ hidden: Bool, forKey key: String) {
        engine.setHidden(hidden, forKey: key)
    }

    /// 移除指定 sprite 的动态隐藏状态，并恢复显示。
    ///
    /// - Parameter key: SVGA 文件中的 sprite `imageKey`。
    public func removeHidden(forKey key: String) {
        engine.removeHidden(forKey: key)
    }

    /// 清除所有动态内容（图片、文本、绘制回调、隐藏状态）。
    public func clearDynamicContent() {
        engine.clearDynamicContent()
    }

    // MARK: - 播放控制

    /// 从当前动画的第一帧开始播放全部帧。
    ///
    /// 需要先通过 `load(_:dynamicContent:startsPlayback:)` 或任一 `play` 方法加载数据。
    public func start() {
        if engine.start() {
            state = .playing
        }
    }

    /// 播放指定帧范围。
    ///
    /// ```swift
    /// // 播放第 10 ~ 30 帧，正向
    /// playerView.start(range: 10..<30, reverse: false)
    ///
    /// // 倒放第 0 ~ 20 帧
    /// playerView.start(range: 0..<20, reverse: true)
    /// ```
    ///
    /// - Parameters:
    ///   - range: 要播放的帧范围。范围会被限制在动画的有效帧范围内。
    ///   - reverse: 是否倒放。
    public func start(range: Range<Int>, reverse: Bool) {
        if engine.start(range: range, reverse: reverse) {
            state = .playing
        }
    }

    /// 暂停动画，保留当前画面。
    public func pause() {
        if engine.pause() {
            state = .paused
        }
    }

    /// 停止动画。
    ///
    /// 同时请求取消当前加载。是否清除画面取决于 `clearsAfterStop`。
    public func stop() {
        stop(cancelLoading: true)
    }

    /// 停止动画，并可选择是否取消正在进行的加载任务。
    ///
    /// - Parameter shouldCancelLoading: `true` 表示同时取消当前加载任务。
    public func stop(cancelLoading shouldCancelLoading: Bool) {
        let wasLoading = state.isLoading
        // 取消引发的状态事件可能已启动新加载，旧调用不能继续停止或清空新请求。
        let sequence = shouldCancelLoading ? cancelLoading(resetState: true) : loadSequence
        guard loadSequence == sequence else { return }
        engine.stop()
        guard loadSequence == sequence else { return }
        state = wasLoading && shouldCancelLoading ? .idle : .stopped
    }

    /// 跳转到指定帧。
    ///
    /// ```swift
    /// // 跳转到第 5 帧并暂停
    /// playerView.seek(toFrame: 5, startsPlayback: false)
    ///
    /// // 跳转到第 10 帧并继续播放
    /// playerView.seek(toFrame: 10, startsPlayback: true)
    /// ```
    ///
    /// - Parameters:
    ///   - frame: 目标帧索引。
    ///   - startsPlayback: `true` 表示跳转后继续播放，`false` 表示跳转后暂停。
    public func seek(toFrame frame: Int, startsPlayback: Bool) {
        if engine.seek(toFrame: frame, startsPlayback: startsPlayback) {
            state = startsPlayback ? .playing : .paused
        }
    }

    /// 跳转到指定进度。
    ///
    /// ```swift
    /// // 跳转到 50% 位置并暂停
    /// playerView.seek(toProgress: 0.5, startsPlayback: false)
    /// ```
    ///
    /// - Parameters:
    ///   - progress: 目标播放进度。取值会被限制在 `0.0...1.0` 范围内。
    ///   - startsPlayback: `true` 表示跳转后继续播放，`false` 表示跳转后暂停。
    public func seek(toProgress progress: CGFloat, startsPlayback: Bool) {
        if engine.seek(toProgress: progress, startsPlayback: startsPlayback) {
            state = startsPlayback ? .playing : .paused
        }
    }

    /// 清除动画画面和所有图层，并请求取消当前加载。
    public func clear() {
        clear(cancelLoading: true)
    }

    /// 清除动画画面和所有图层，并可选择是否取消正在进行的加载任务。
    ///
    /// - Parameter shouldCancelLoading: `true` 表示同时取消当前加载任务。
    public func clear(cancelLoading shouldCancelLoading: Bool) {
        // 取消引发的状态事件可能已启动新加载，旧调用不能继续停止或清空新请求。
        let sequence = shouldCancelLoading ? cancelLoading(resetState: true) : loadSequence
        guard loadSequence == sequence else { return }
        engine.clear()
        guard loadSequence == sequence else { return }
        state = .idle
    }
}

// MARK: - 播放引擎事件转发

extension SVGAView: SVGAPlaybackEngineDelegate {
    func svgaPlaybackEngineDidFinishAnimation(_ engine: SVGAPlaybackEngine) {
        let sequence = loadSequence
        state = .stopped
        // 状态事件可同步替换加载；旧播放完成事件不得落到新请求上。
        guard loadSequence == sequence else { return }
        emit(.finished)
    }

    func svgaPlaybackEngine(_ engine: SVGAPlaybackEngine, didAnimateToFrame frame: Int) {
        emit(.frameChanged(frame))
    }

    func svgaPlaybackEngine(_ engine: SVGAPlaybackEngine, didAnimateToPercentage percentage: CGFloat) {
        emit(.percentageChanged(percentage))
    }
}
