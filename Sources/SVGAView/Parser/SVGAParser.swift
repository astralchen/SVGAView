import UIKit
import SwiftProtobuf
import CryptoKit

typealias SVGADownloadProgressHandler = SVGAViewPreloadProgressHandler

/// 解析 SVGA 文件的 actor。
///
/// `SVGAParser` 支持 SVGA 2.x Proto 格式和 SVGA 1.x JSON 格式。
/// 解析器会复用内存缓存和磁盘缓存，并在需要时自动解压 ZIP 或 zlib 数据。
///
/// ```swift
/// let entity = try await SVGAParser.shared.parse(named: "banner")
/// let entity = try await SVGAParser.shared.parse(url: url)
/// let entity = try await SVGAParser.shared.parse(data: svgaData, cacheKey: "myKey")
/// ```
actor SVGAParser {
    /// 供默认预下载和视图加载共同使用的解析器。
    static let shared = SVGAParser()

    /// 一个布尔值，指示是否启用强引用内存缓存。
    ///
    /// 默认值为 `true`。设置为 `false` 后，解析器仍会写入弱引用缓存。
    var enabledMemoryCache: Bool = true

    /// 允许下载的最大 SVGA 文件大小，单位为字节。
    ///
    /// 下载数据超过该值时会抛出 `SVGAParserError.fileTooLarge`。
    /// 默认值为 50 MB。
    var maxDownloadSize: Int = 50_000_000

    private let requests = SVGASharedRequests<SVGA.VideoEntity>()
    private let configuration: URLSessionConfiguration?
    private let cacheDirectory: URL?
    /// 测试使用的提交前门控；位于解析完成与正式缓存发布之间，生产环境默认为 `nil`。
    private let beforeCacheCommit: (@Sendable () async -> Void)?

    init(configuration: URLSessionConfiguration? = nil, cacheDirectory: URL? = nil,
         beforeCacheCommit: (@Sendable () async -> Void)? = nil) {
        self.configuration = configuration
        self.cacheDirectory = cacheDirectory
        self.beforeCacheCommit = beforeCacheCommit
    }

    // MARK: - 解析入口

    /// 从远程 URL 下载并解析 SVGA 文件。
    ///
    /// - Parameters:
    ///   - url: SVGA 文件的远程 URL。
    ///   - progressHandler: 可选的下载进度回调。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 取消时抛出 `CancellationError`；否则传播下载、解压或解析错误。
    func parse(url: URL, progressHandler: SVGADownloadProgressHandler? = nil) async throws -> SVGA.VideoEntity {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        return try await parse(request: request, progressHandler: progressHandler)
    }

    /// 使用自定义请求下载并解析 SVGA 文件。
    ///
    /// - Parameters:
    ///   - request: 用于下载 SVGA 文件的请求。
    ///   - progressHandler: 可选的下载进度回调。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 取消时抛出 `CancellationError`；否则传播下载、解压或解析错误。
    func parse(request: URLRequest, progressHandler: SVGADownloadProgressHandler? = nil) async throws -> SVGA.VideoEntity {
        try Task.checkCancellation()
        guard let url = request.url else { throw SVGAParserError.invalidURL }
        let key = cacheKey(for: url)
        let maximumSize = maxDownloadSize
        let configuration = self.configuration
        return try await requests.value(for: key, progress: { value, isActive in
            guard isActive() else { return }
            progressHandler?(value)
        }) { lease, progress in
            if let cached = try await self.cachedEntity(key: key, lease: lease) { return cached }
            await progress(0)
            try lease.checkCancellation()
            let data = try await SVGADataDownloader.download(
                request: request, maximumSize: maximumSize,
                progressHandler: { value in Task { await progress(value) } },
                configuration: configuration
            )
            return try await self.parseData(data, cacheKey: key, lease: lease)
        }
    }

    /// 从原始数据解析 SVGA 文件。
    ///
    /// 解析器会自动检测 ZIP 和 zlib 数据，并将解压后的文件写入磁盘缓存。
    ///
    /// - Parameters:
    ///   - data: SVGA 文件数据。
    ///   - key: 用于读写内存缓存和磁盘缓存的稳定 key。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 取消时抛出 `CancellationError`；否则传播解压或解析错误。
    func parse(data: Data, cacheKey key: String) async throws -> SVGA.VideoEntity {
        try await requests.value(for: key, progress: { _, _ in }) { lease, _ in
            try await self.parseData(data, cacheKey: key, lease: lease)
        }
    }

    /// 读取可复用实体，并在异步缓存读取或同步解析完成后重新检查租约。
    private func cachedEntity(key: String, lease: SVGAWorkLease) async throws -> SVGA.VideoEntity? {
        try lease.checkCancellation()
        if let cached = await SVGACacheStore.shared.read(key: key) {
            try lease.checkCancellation()
            return cached
        }
        let directory = cacheDirURL(for: key)
        guard hasDiskCache(cacheDir: directory) else { return nil }
        do {
            let entity = try loadFromDisk(cacheDir: directory, cacheKey: key)
            try lease.checkCancellation()
            return entity
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// 在实例独占的暂存目录中完成解压和解析，成功后再发布正式缓存。
    private func parseData(_ data: Data, cacheKey key: String, lease: SVGAWorkLease) async throws -> SVGA.VideoEntity {
        if let cached = try await cachedEntity(key: key, lease: lease) { return cached }
        let cacheDir = cacheDirURL(for: key)
        // 暂存目录不使用正式缓存键，避免取消后的半成品被状态查询识别为可用缓存。
        let staging = cacheDir.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        // 失败或取消只清理自己的暂存目录，不触碰同键后续请求的文件。
        defer { try? FileManager.default.removeItem(at: staging) }
        try lease.checkCancellation()
        if SVGADecompressor.isZIP(data) {
            try SVGADecompressor.unzip(data, to: staging)
        } else {
            let inflated = try SVGADecompressor.inflate(data)
            try lease.checkCancellation()
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try inflated.write(to: staging.appendingPathComponent("movie.binary"), options: .atomic)
        }
        try lease.checkCancellation()
        // 实体在解析时持有图片和音频数据，不保留暂存目录路径；目录迁移后仍可直接播放。
        // 同步解析无法强制抢占，在返回后再次检查取消，防止发布已失效的结果。
        let entity = try loadFromDisk(cacheDir: staging, cacheKey: key)
        try lease.checkCancellation()
        await beforeCacheCommit?()
        try lease.checkCancellation()
        // 磁盘提交和内存发布使用同一租约；取消不能插入两者之间。
        try await SVGACacheStore.shared.publish(key: key, entity: entity, strong: enabledMemoryCache, lease: lease) {
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.removeItem(at: cacheDir)
            }
            try FileManager.default.moveItem(at: staging, to: cacheDir)
        }
        return entity
    }

    /// 从 bundle 中按资源名加载并解析 SVGA 文件。
    ///
    /// - Parameters:
    ///   - named: 资源名（不含 `.svga` 扩展名）。
    ///   - bundle: 资源所在的 bundle。传入 `nil` 时使用 `Bundle.main`。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 取消时抛出 `CancellationError`；否则传播读取、解压或解析错误。
    func parse(named: String, in bundle: Bundle? = nil) async throws -> SVGA.VideoEntity {
        try Task.checkCancellation()
        let b = bundle ?? Bundle.main
        guard let fileURL = b.url(forResource: named, withExtension: "svga")
               ?? b.url(forResource: named, withExtension: nil) else {
            throw SVGAParserError.resourceNotFound(named)
        }
        let data = try Data(contentsOf: fileURL)
        let key = sha256(data)
        return try await parse(data: data, cacheKey: key)
    }

    /// 从本地文件 URL 读取并解析 SVGA 文件。
    ///
    /// - Parameter fileURL: 指向 SVGA 文件的本地文件 URL。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 取消时抛出 `CancellationError`；否则传播读取、解压或解析错误。
    func parse(fileURL: URL) async throws -> SVGA.VideoEntity {
        try Task.checkCancellation()
        guard fileURL.isFileURL else {
            throw SVGAParserError.invalidURL
        }
        let data = try Data(contentsOf: fileURL)
        let key = sha256(data)
        return try await parse(data: data, cacheKey: key)
    }

    /// 查询远程 URL 对应的缓存状态。
    func cacheStatus(url: URL) async -> SVGACacheStatus {
        await cacheStatus(cacheKey: cacheKey(for: url))
    }

    /// 查询自定义请求对应的远程 URL 缓存状态。
    func cacheStatus(request: URLRequest) async -> SVGACacheStatus {
        guard let url = request.url else { return .missing }
        return await cacheStatus(url: url)
    }

    /// 查询 bundle 中资源的缓存状态。
    func cacheStatus(named: String, in bundle: Bundle? = nil) async -> SVGACacheStatus {
        let b = bundle ?? Bundle.main
        guard let fileURL = b.url(forResource: named, withExtension: "svga")
               ?? b.url(forResource: named, withExtension: nil),
              let data = try? Data(contentsOf: fileURL) else {
            return .missing
        }
        return await cacheStatus(cacheKey: sha256(data))
    }

    /// 查询本地文件 URL 的缓存状态。
    func cacheStatus(fileURL: URL) async -> SVGACacheStatus {
        guard fileURL.isFileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return .missing
        }
        return await cacheStatus(cacheKey: sha256(data))
    }

    /// 查询调用方指定的 data cache key 缓存状态。
    func cacheStatus(dataCacheKey key: String) async -> SVGACacheStatus {
        await cacheStatus(cacheKey: key)
    }

    // MARK: - 私有辅助方法

    private func cacheStatus(cacheKey key: String) async -> SVGACacheStatus {
        let cacheDir = cacheDirURL(for: key)
        if await SVGACacheStore.shared.read(key: key) != nil || hasDiskCache(cacheDir: cacheDir) {
            return .cached(localPath: cacheDir.path)
        }
        let status = requests.status(for: key)
        if status.isDownloading { return .downloading(progress: status.progress) }
        return .missing
    }

    private func hasDiskCache(cacheDir: URL) -> Bool {
        let binaryPath = cacheDir.appendingPathComponent("movie.binary").path
        let specPath = cacheDir.appendingPathComponent("movie.spec").path
        return FileManager.default.fileExists(atPath: binaryPath)
            || FileManager.default.fileExists(atPath: specPath)
    }

    private func loadFromDisk(cacheDir: URL, cacheKey key: String) throws -> SVGA.VideoEntity {
        let binaryPath = cacheDir.appendingPathComponent("movie.binary").path
        let specPath = cacheDir.appendingPathComponent("movie.spec").path
        if FileManager.default.fileExists(atPath: binaryPath) {
            let protoData = try Data(contentsOf: URL(fileURLWithPath: binaryPath))
            return try parseProto(data: protoData, cacheDir: cacheDir.path, cacheKey: key)
        } else if FileManager.default.fileExists(atPath: specPath) {
            let jsonData = try Data(contentsOf: URL(fileURLWithPath: specPath))
            return try parseJSON(data: jsonData, cacheDir: cacheDir.path, cacheKey: key)
        }
        throw SVGAParserError.missingMovieFile
    }

    private func parseProto(data: Data, cacheDir: String, cacheKey key: String) throws -> SVGA.VideoEntity {
        let proto = try SVGAProto.Movie(serializedBytes: data)
        return SVGA.VideoEntity(protoObject: proto, cacheDir: cacheDir)
    }

    private func parseJSON(data: Data, cacheDir: String, cacheKey key: String) throws -> SVGA.VideoEntity {
        guard case .object(let jsonObject) = try JSONDecoder().decode(SVGAJSONValue.self, from: data) else {
            throw SVGAParserError.invalidJSON
        }
        return SVGA.VideoEntity(jsonObject: jsonObject, cacheDir: cacheDir)
    }

    private func cacheDirURL(for key: String) -> URL {
        if let cacheDirectory { return cacheDirectory.appendingPathComponent(key) }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SVGACache").appendingPathComponent(key)
        }
        return caches.appendingPathComponent("SVGACache").appendingPathComponent(key)
    }

    private func cacheKey(for url: URL) -> String {
        return sha256(url.absoluteString)
    }

    private func cacheKey(for named: String) -> String {
        return sha256(named)
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - 解析错误

/// SVGA 解析过程中产生的错误。
enum SVGAParserError: Error {
    /// URL 缺失或不是有效的文件 URL。
    case invalidURL
    /// 在指定 bundle 中找不到资源。
    case resourceNotFound(String)
    /// SVGA 压缩包中缺少 `movie.binary` 或 `movie.spec`。
    case missingMovieFile
    /// SVGA JSON 数据格式无效。
    case invalidJSON
    /// 下载文件超过允许的大小限制。
    case fileTooLarge
}

/// 测试使用的 URLSession 注入点。
enum SVGAURLSessionTestHooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var classes: [AnyClass]?
    static var protocolClasses: [AnyClass]? {
        get { lock.lock(); defer { lock.unlock() }; return classes }
        set { lock.lock(); classes = newValue; lock.unlock() }
    }
}

/// 下载 SVGA 文件并报告进度的 URLSession 代理。
final class SVGADataDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumSize: Int
    private let progressHandler: SVGADownloadProgressHandler?
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.svga.player.download"
        return queue
    }()

    // 所有可变下载状态仅在串行 delegateQueue 中访问，包括创建、取消和代理回调。
    private var data = Data()
    private var expectedContentLength: Int64 = NSURLSessionTransferSizeUnknown
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var isCompleted = false
    private var cancellationRequested = false
    private var dataTask: URLSessionDataTask?

    private init(maximumSize: Int, progressHandler: SVGADownloadProgressHandler?) {
        self.maximumSize = maximumSize
        self.progressHandler = progressHandler
    }

    static func download(
        request: URLRequest,
        maximumSize: Int,
        progressHandler: SVGADownloadProgressHandler?,
        configuration: URLSessionConfiguration? = nil
    ) async throws -> Data {
        let downloader = SVGADataDownloader(maximumSize: maximumSize, progressHandler: progressHandler)
        return try await downloader.download(request: request, configuration: configuration)
    }

    private func download(request: URLRequest, configuration suppliedConfiguration: URLSessionConfiguration?) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegateQueue.addOperation {
                    // 取消可能先于 continuation 登记完成，此时不得创建网络请求。
                    guard !self.isCompleted, !self.cancellationRequested else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    let configuration = suppliedConfiguration ?? URLSessionConfiguration.default
                    configuration.requestCachePolicy = request.cachePolicy
                    if suppliedConfiguration == nil, let protocolClasses = SVGAURLSessionTestHooks.protocolClasses {
                        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
                    }
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: self.delegateQueue)
                    self.session = session
                    let task = session.dataTask(with: request)
                    self.dataTask = task
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// 在代理队列中登记取消；已启动请求等待终态回调后再结束异步等待。
    private func cancel() {
        delegateQueue.addOperation {
            guard !self.isCompleted else { return }
            self.cancellationRequested = true
            if let task = self.dataTask { task.cancel() }
            else { self.complete(.failure(CancellationError())) }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isCompleted, !cancellationRequested else {
            completionHandler(.cancel)
            return
        }
        expectedContentLength = response.expectedContentLength
        if expectedContentLength > Int64(maximumSize) {
            complete(.failure(SVGAParserError.fileTooLarge))
            completionHandler(.cancel)
            return
        }
        reportProgress(receivedBytes: 0)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive receivedData: Data) {
        guard !isCompleted, !cancellationRequested else { return }
        data.append(receivedData)
        guard data.count <= maximumSize else {
            complete(.failure(SVGAParserError.fileTooLarge))
            dataTask.cancel()
            return
        }
        reportProgress(receivedBytes: data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isCompleted else { return }
        if cancellationRequested {
            complete(.failure(CancellationError()))
            return
        }
        if let error {
            complete(.failure(error))
            return
        }
        reportProgress(receivedBytes: data.count, forceComplete: true)
        complete(.success(data))
    }

    private func reportProgress(receivedBytes: Int, forceComplete: Bool = false) {
        guard let progressHandler else { return }
        if forceComplete {
            progressHandler(1.0)
            return
        }
        guard expectedContentLength > 0 else {
            progressHandler(0.0)
            return
        }
        let progress = min(1.0, max(0.0, Double(receivedBytes) / Double(expectedContentLength)))
        progressHandler(progress)
    }

    /// 确定唯一终态，并在恢复等待者前撤销句柄和释放下载缓冲。
    private func complete(_ result: Result<Data, Error>) {
        guard !isCompleted else { return }
        isCompleted = true

        let session = self.session
        let continuation = self.continuation
        self.session = nil
        self.dataTask = nil
        self.continuation = nil
        data = Data()

        switch result {
        case .success(let data):
            session?.finishTasksAndInvalidate()
            continuation?.resume(returning: data)
        case .failure(let error):
            session?.invalidateAndCancel()
            continuation?.resume(throwing: error)
        }
    }
}
