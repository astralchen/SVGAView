import Foundation

/// 按资源键共享异步工作，并为每个调用方维护独立订阅。
///
/// 取消单个订阅不影响其他订阅者。最后一个订阅取消后，旧实例保留到工作实际
/// 退出及清理完成；同键的新订阅等待下一实例，不继承旧实例的取消结果。
///
/// 全部可变订阅和实例状态由同一把锁保护。用户进度回调、任务取消和
/// continuation 恢复均在锁外执行，允许调用方在回调中重新提交或取消。
final class SVGASharedRequests<Value: Sendable>: @unchecked Sendable {
    /// 进度接收器；须在实际派发回调前调用有效性检查闭包，过滤跨执行器排队期间的取消。
    typealias Progress = @Sendable (Double, @Sendable () -> Bool) async -> Void
    /// 共享工作入口；通过租约在阶段边界检查取消，并串行化最终缓存提交。
    typealias Operation = @Sendable (SVGAWorkLease, @escaping @Sendable (Double) async -> Void) async throws -> Value

    /// 独立等待者；`result` 是首次确定的终态，确定后不能被迟到取消改写。
    private final class Subscriber: @unchecked Sendable {
        let id = UUID()
        let progress: Progress
        let operation: Operation
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
        var cancelled = false
        init(progress: @escaping Progress, operation: @escaping Operation) {
            self.progress = progress
            self.operation = operation
        }
    }
    /// 单次共享工作实例；`next` 仅存放旧实例清理期间到达的新订阅。
    private final class Entry {
        let id = UUID()
        let lease = SVGAWorkLease()
        var task: Task<Void, Never>?
        var subscribers: [Subscriber] = []
        var next: [Subscriber] = []
        var closing = false
        var progress: Double?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// 订阅指定资源的共享工作，并等待当前订阅的结果。
    ///
    /// - Parameters:
    ///   - key: 用于合并资源加载的稳定键。
    ///   - progress: 当前订阅的进度接收器。
    ///   - operation: 新实例需要执行的工作；同一实例使用首个订阅提供的操作。
    /// - Returns: 共享工作返回的值。
    /// - Throws: 订阅取消时抛出 `CancellationError`；否则传播工作自身的错误。
    ///   最后一个订阅取消后，需等待共享工作退出及清理完成。
    func value(for key: String, progress: @escaping Progress, operation: @escaping Operation) async throws -> Value {
        try Task.checkCancellation()
        let subscriber = Subscriber(progress: progress, operation: operation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(subscriber, key: key, continuation: continuation)
            }
        } onCancel: {
            self.cancel(subscriber, key: key)
        }
    }

    /// 返回当前工作快照；正在取消但尚未退出的实例仍视为进行中。
    func status(for key: String) -> (isDownloading: Bool, progress: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return (false, nil) }
        return (true, entry.progress)
    }

    private func register(_ subscriber: Subscriber, key: String, continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        // 取消处理器可能先于 continuation 登记执行，不能因此启动新的底层工作。
        if subscriber.cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        subscriber.continuation = continuation
        if let entry = entries[key] {
            if entry.closing {
                entry.next.append(subscriber)
            } else {
                entry.subscribers.append(subscriber)
            }
            let progress = entry.closing ? nil : entry.progress
            lock.unlock()
            if let progress { Task { await self.report(progress, to: subscriber) } }
        } else {
            start(key: key, subscribers: [subscriber])
            lock.unlock()
        }
    }

    // 仅在持锁时调用。先登记实例再创建任务，确保完成回调总能找到所属实例。
    private func start(key: String, subscribers: [Subscriber]) {
        let entry = Entry()
        entry.subscribers = subscribers
        entries[key] = entry
        let operation = subscribers[0].operation
        let id = entry.id
        let lease = entry.lease
        entry.task = Task {
            let result: Result<Value, Error>
            do {
                try lease.checkCancellation()
                result = .success(try await operation(lease) { value in
                    await self.report(value, key: key, id: id)
                })
            } catch { result = .failure(error) }
            await self.finish(result, key: key, id: id)
        }
    }

    private func cancel(_ subscriber: Subscriber, key: String) {
        lock.lock()
        guard subscriber.result == nil, !subscriber.cancelled else { lock.unlock(); return }
        subscriber.cancelled = true
        var task: Task<Void, Never>?
        var continuation: CheckedContinuation<Value, Error>?
        if let entry = entries[key], entry.subscribers.contains(where: { $0 === subscriber }) {
            if entry.subscribers.allSatisfy({ $0.cancelled }) {
                entry.closing = true
                entry.lease.cancel()
                task = entry.task
                // 最后一个等待者保留 continuation，直到下载、解析及暂存清理实际结束。
            } else {
                entry.subscribers.removeAll { $0 === subscriber }
                continuation = subscriber.continuation
                subscriber.continuation = nil
                subscriber.result = .failure(CancellationError())
            }
        } else {
            entries[key]?.next.removeAll { $0 === subscriber }
            continuation = subscriber.continuation
            subscriber.continuation = nil
            subscriber.result = .failure(CancellationError())
        }
        lock.unlock()
        // 取消处理器和恢复后的调用方都可能重入，必须先完成状态变更并解锁。
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func progressAllowed(_ subscriber: Subscriber, completed: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !subscriber.cancelled && (completed || subscriber.result == nil)
    }

    private func report(_ value: Double, to subscriber: Subscriber, completed: Bool = false) async {
        await subscriber.progress(value) { self.progressAllowed(subscriber, completed: completed) }
    }

    private func recordProgress(_ value: Double, key: String, id: UUID) -> [Subscriber] {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.id == id, !entry.closing else { return [] }
        entry.progress = value
        return entry.subscribers
    }

    private func report(_ value: Double, key: String, id: UUID) async {
        for subscriber in recordProgress(value, key: key, id: id) {
            await report(value, to: subscriber)
        }
    }

    /// 在锁内确定订阅终态并接续下一实例，将回调和 continuation 恢复留给锁外。
    private func takeCompleted(_ result: Result<Value, Error>, key: String, id: UUID)
        -> [(Subscriber, CheckedContinuation<Value, Error>, Result<Value, Error>, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        // 同键可能已登记新实例；旧完成回调只能结束自己的实例。
        guard let entry = entries[key], entry.id == id else { return [] }
        entries[key] = nil
        let completed = entry.subscribers.compactMap { subscriber -> (Subscriber, CheckedContinuation<Value, Error>, Result<Value, Error>, Bool)? in
            let terminal: Result<Value, Error> = subscriber.cancelled ? .failure(CancellationError()) : result
            subscriber.result = terminal
            guard let continuation = subscriber.continuation else { return nil }
            subscriber.continuation = nil
            return (subscriber, continuation, terminal, entry.progress != nil)
        }
        if !entry.next.isEmpty { start(key: key, subscribers: entry.next) }
        return completed
    }

    // 终态先于最终进度回调确定，回调中发生的取消不能反向改写已确定的成功。
    private func finish(_ result: Result<Value, Error>, key: String, id: UUID) async {
        for (subscriber, continuation, terminal, hadProgress) in takeCompleted(result, key: key, id: id) {
            // 缓存读取没有下载进度，不能仅因加载成功而合成下载完成事件。
            if case .success = terminal, hadProgress { await report(1, to: subscriber, completed: true) }
            continuation.resume(with: terminal)
        }
    }
}

/// 将共享工作的取消与同步缓存提交串行化的租约。
///
/// 同步解压和解析不能被强制中断，调用方应在阶段边界检查租约。提交闭包仅可
/// 执行内部同步缓存操作，不得调用用户代码或重入租约，以免在持锁期间死锁。
final class SVGAWorkLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func checkCancellation() throws { try commit {} }
    /// 在租约有效时执行同步提交，并阻止取消插入提交过程。
    ///
    /// - Parameter body: 仅包含内部同步缓存操作的闭包。
    /// - Returns: 提交闭包的结果。
    /// - Throws: 租约已取消时抛出 `CancellationError`；否则传播提交错误。
    func commit<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        return try body()
    }
}
