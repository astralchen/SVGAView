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

    private struct InFlightParse {
        let task: Task<SVGA.VideoEntity, Error>
        var waiterIDs: Set<UUID>
        var progressHandlers: [UUID: SVGADownloadProgressHandler]
        var lastProgress: Double?
    }

    private struct InFlightWaiter {
        let id: UUID
        let task: Task<SVGA.VideoEntity, Error>
        let progressHandler: SVGADownloadProgressHandler?
        let progressToReplay: Double?
    }

    private var inFlightParses: [String: InFlightParse] = [:]

    // MARK: - Public API

    /// 从远程 URL 下载并解析 SVGA 文件。
    ///
    /// - Parameters:
    ///   - url: SVGA 文件的远程 URL。
    ///   - progressHandler: 可选的下载进度回调。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 下载、解压或解析失败时抛出错误。
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
    /// - Throws: 下载、解压或解析失败时抛出错误。
    func parse(request: URLRequest, progressHandler: SVGADownloadProgressHandler? = nil) async throws -> SVGA.VideoEntity {
        guard let url = request.url else {
            throw SVGAParserError.invalidURL
        }
        let key = cacheKey(for: url)
        if let cached = await SVGACacheStore.shared.read(key: key) {
            progressHandler?(1.0)
            return cached
        }
        let cacheDir = cacheDirURL(for: key)
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            if let entity = try? await loadFromDisk(cacheDir: cacheDir, cacheKey: key) {
                progressHandler?(1.0)
                return entity
            }
            try? FileManager.default.removeItem(at: cacheDir)
        }
        if let waiter = addWaiterToInFlightParse(cacheKey: key, progressHandler: progressHandler) {
            return try await awaitInFlightParse(
                waiter,
                cacheKey: key
            )
        }

        let maximumSize = maxDownloadSize
        let task = Task { [request, key, maximumSize] in
            let data = try await SVGADataDownloader.download(
                request: request,
                maximumSize: maximumSize,
                progressHandler: { progress in
                    Task {
                        let recorded = await self.recordInFlightProgress(progress, cacheKey: key)
                        recorded.handlers.forEach { $0(recorded.progress) }
                    }
                }
            )
            return try await self.parseData(data, cacheKey: key)
        }
        let waiter = storeInFlightParse(task, cacheKey: key, progressHandler: progressHandler)
        return try await awaitInFlightParse(waiter, cacheKey: key)
    }

    /// 从原始数据解析 SVGA 文件。
    ///
    /// 解析器会自动检测 ZIP 和 zlib 数据，并将解压后的文件写入磁盘缓存。
    ///
    /// - Parameters:
    ///   - data: SVGA 文件数据。
    ///   - key: 用于读写内存缓存和磁盘缓存的稳定 key。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 解压或解析失败时抛出错误。
    func parse(data: Data, cacheKey key: String) async throws -> SVGA.VideoEntity {
        try await parseData(data, cacheKey: key)
    }

    private func parseData(_ data: Data, cacheKey key: String) async throws -> SVGA.VideoEntity {
        if let cached = await SVGACacheStore.shared.read(key: key) {
            return cached
        }
        let cacheDir = cacheDirURL(for: key)
        if FileManager.default.fileExists(atPath: cacheDir.path),
           let entity = try? await loadFromDisk(cacheDir: cacheDir, cacheKey: key) {
            return entity
        }
        let entity: SVGA.VideoEntity
        if SVGADecompressor.isZIP(data) {
            try SVGADecompressor.unzip(data, to: cacheDir)
            entity = try await loadFromDisk(cacheDir: cacheDir, cacheKey: key)
        } else {
            let inflated = try SVGADecompressor.inflate(data)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try inflated.write(to: cacheDir.appendingPathComponent("movie.binary"), options: .atomic)
            entity = try parseProto(data: inflated, cacheDir: cacheDir.path, cacheKey: key)
        }
        await cacheEntity(entity, key: key)
        return entity
    }

    /// 从 bundle 中按资源名加载并解析 SVGA 文件。
    ///
    /// - Parameters:
    ///   - named: 资源名（不含 `.svga` 扩展名）。
    ///   - bundle: 资源所在的 bundle。传入 `nil` 时使用 `Bundle.main`。
    /// - Returns: 解析后的动画实体。
    /// - Throws: 读取、解压或解析失败时抛出错误。
    func parse(named: String, in bundle: Bundle? = nil) async throws -> SVGA.VideoEntity {
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
    /// - Throws: 读取、解压或解析失败时抛出错误。
    func parse(fileURL: URL) async throws -> SVGA.VideoEntity {
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

    // MARK: - Private helpers

    private func cacheStatus(cacheKey key: String) async -> SVGACacheStatus {
        let cacheDir = cacheDirURL(for: key)
        if await SVGACacheStore.shared.read(key: key) != nil || hasDiskCache(cacheDir: cacheDir) {
            return .cached(localPath: cacheDir.path)
        }
        if let inFlight = inFlightParses[key] {
            return .downloading(progress: inFlight.lastProgress)
        }
        return .missing
    }

    private func hasDiskCache(cacheDir: URL) -> Bool {
        let binaryPath = cacheDir.appendingPathComponent("movie.binary").path
        let specPath = cacheDir.appendingPathComponent("movie.spec").path
        return FileManager.default.fileExists(atPath: binaryPath)
            || FileManager.default.fileExists(atPath: specPath)
    }

    private func loadFromDisk(cacheDir: URL, cacheKey key: String) async throws -> SVGA.VideoEntity {
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

    private func cacheEntity(_ entity: SVGA.VideoEntity, key: String) async {
        if enabledMemoryCache {
            await SVGACacheStore.shared.save(key: key, entity: entity)
        } else {
            await SVGACacheStore.shared.saveWeak(key: key, entity: entity)
        }
    }

    private func addWaiterToInFlightParse(
        cacheKey key: String,
        progressHandler: SVGADownloadProgressHandler?
    ) -> InFlightWaiter? {
        guard var inFlight = inFlightParses[key] else { return nil }
        let waiterID = UUID()
        inFlight.waiterIDs.insert(waiterID)
        if let progressHandler {
            inFlight.progressHandlers[waiterID] = progressHandler
        }
        inFlightParses[key] = inFlight
        return InFlightWaiter(
            id: waiterID,
            task: inFlight.task,
            progressHandler: progressHandler,
            progressToReplay: inFlight.lastProgress
        )
    }

    private func storeInFlightParse(
        _ task: Task<SVGA.VideoEntity, Error>,
        cacheKey key: String,
        progressHandler: SVGADownloadProgressHandler?
    ) -> InFlightWaiter {
        let waiterID = UUID()
        var progressHandlers: [UUID: SVGADownloadProgressHandler] = [:]
        if let progressHandler {
            progressHandlers[waiterID] = progressHandler
        }
        inFlightParses[key] = InFlightParse(
            task: task,
            waiterIDs: [waiterID],
            progressHandlers: progressHandlers,
            lastProgress: nil
        )
        return InFlightWaiter(
            id: waiterID,
            task: task,
            progressHandler: progressHandler,
            progressToReplay: nil
        )
    }

    private func recordInFlightProgress(
        _ progress: Double,
        cacheKey key: String
    ) -> (progress: Double, handlers: [SVGADownloadProgressHandler]) {
        let boundedProgress = min(1.0, max(0.0, progress))
        guard var inFlight = inFlightParses[key] else {
            return (boundedProgress, [])
        }
        inFlight.lastProgress = boundedProgress
        let handlers = Array(inFlight.progressHandlers.values)
        inFlightParses[key] = inFlight
        return (boundedProgress, handlers)
    }

    private func awaitInFlightParse(
        _ waiter: InFlightWaiter,
        cacheKey key: String
    ) async throws -> SVGA.VideoEntity {
        defer {
            releaseInFlightParseWaiter(cacheKey: key, waiterID: waiter.id)
        }
        if let progress = waiter.progressToReplay {
            waiter.progressHandler?(progress)
        }
        let entity = try await withTaskCancellationHandler {
            let entity = try await waiter.task.value
            try Task.checkCancellation()
            return entity
        } onCancel: {
            Task {
                await self.releaseInFlightParseWaiter(cacheKey: key, waiterID: waiter.id)
            }
        }
        return entity
    }

    private func releaseInFlightParseWaiter(cacheKey key: String, waiterID: UUID) {
        guard var inFlight = inFlightParses[key],
              inFlight.waiterIDs.remove(waiterID) != nil
        else { return }

        inFlight.progressHandlers[waiterID] = nil

        if inFlight.waiterIDs.isEmpty {
            inFlight.task.cancel()
            inFlightParses[key] = nil
        } else {
            inFlightParses[key] = inFlight
        }
    }

    private func cacheDirURL(for key: String) -> URL {
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

// MARK: - Errors

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
    nonisolated(unsafe) static var protocolClasses: [AnyClass]?
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

    // All mutable state is confined to delegateQueue, including setup and cancellation.
    private var data = Data()
    private var expectedContentLength: Int64 = NSURLSessionTransferSizeUnknown
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var isCompleted = false

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
                    // Cancellation may have completed before the continuation was installed.
                    guard !self.isCompleted else {
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
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        delegateQueue.addOperation {
            self.complete(.failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isCompleted else {
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
        guard !isCompleted else { return }
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

    private func complete(_ result: Result<Data, Error>) {
        guard !isCompleted else { return }
        isCompleted = true

        let session = self.session
        let continuation = self.continuation
        self.session = nil
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
