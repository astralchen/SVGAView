import Foundation

/// 保存已解析 SVGA 动画实体的内存缓存。
///
/// 缓存同时维护强引用和弱引用两种存储方式，用于支持解析器的可配置缓存策略。
actor SVGACacheStore {
    /// 共享缓存实例。
    static let shared = SVGACacheStore()

    private let strongCache = NSCache<NSString, SVGA.VideoEntity>()
    private let weakCache = NSMapTable<NSString, SVGA.VideoEntity>(
        keyOptions: .strongMemory,
        valueOptions: .weakMemory
    )

    /// 读取指定 key 对应的动画实体。
    ///
    /// - Parameter key: 缓存 key。
    /// - Returns: 命中缓存时返回动画实体，否则返回 `nil`。
    func read(key: String) -> SVGA.VideoEntity? {
        let k = key as NSString
        return strongCache.object(forKey: k) ?? weakCache.object(forKey: k)
    }

    /// 保存动画实体到强引用缓存。
    ///
    /// - Parameters:
    ///   - key: 缓存 key。
    ///   - entity: 要缓存的动画实体。
    func save(key: String, entity: SVGA.VideoEntity) {
        strongCache.setObject(entity, forKey: key as NSString)
    }

    /// 保存动画实体到弱引用缓存。
    ///
    /// - Parameters:
    ///   - key: 缓存 key。
    ///   - entity: 要缓存的动画实体。
    func saveWeak(key: String, entity: SVGA.VideoEntity) {
        weakCache.setObject(entity, forKey: key as NSString)
    }
    /// 提交完整的磁盘缓存，并发布对应的内存实体。
    ///
    /// 租约将取消与整个同步提交过程串行化。磁盘提交失败时不会发布内存实体，
    /// 租约已取消时两者均不执行。
    ///
    /// - Parameters:
    ///   - key: 正式缓存键。
    ///   - entity: 已完成解析且不依赖暂存路径的动画实体。
    ///   - strong: `true` 表示写入强引用缓存；否则写入弱引用缓存。
    ///   - lease: 当前共享工作实例的取消租约。
    ///   - commitDisk: 将暂存内容提交至正式缓存的同步操作，不得调用用户代码或重入租约。
    /// - Throws: 租约已取消时抛出 `CancellationError`；否则传播磁盘提交错误。
    func publish(key: String, entity: SVGA.VideoEntity, strong: Bool, lease: SVGAWorkLease,
                 commitDisk: @Sendable () throws -> Void) throws {
        try lease.commit {
            try commitDisk()
            if strong { strongCache.setObject(entity, forKey: key as NSString) }
            else { weakCache.setObject(entity, forKey: key as NSString) }
        }
    }

}
