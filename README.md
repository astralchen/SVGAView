# SVGAView

A lightweight, high-performance SVGA animation view for iOS, built with Swift 6 strict concurrency.

Supports both **Proto 2.x** and **JSON 1.x** SVGA formats, with audio playback, dynamic content replacement, and frame-level control.

## Requirements

- iOS 15.0+
- Swift 6.3+ toolchain (Swift 6 language mode)
- Xcode 26.4+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/astralchen/SVGAView.git", from: "1.0.0")
]
```

Or in Xcode: **File > Add Package Dependencies**, enter the repository URL.

## Development

Open **SVGAView.xcworkspace** at the repository root. The workspace contains the
local Swift package and the Examples app, with two shared schemes:

- **SVGAView** — build the framework and run its unit tests.
- **Examples** — run the demo app and its unit and UI tests.

The framework's targets and dependencies remain defined in `Package.swift`.
Dependencies are SwiftProtobuf 1.38.1+ (including its code-generation plugin)
and ZIPFoundation 0.9.20+.
Both the package and workspace lockfiles are committed; keep their dependency
versions aligned when intentionally updating dependencies.

To build from the command line:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
open SVGAView.xcworkspace

xcodebuild -workspace SVGAView.xcworkspace -scheme SVGAView \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -workspace SVGAView.xcworkspace -scheme Examples \
  -configuration Release -destination 'generic/platform=iOS Simulator' build
```

List available simulators with `xcrun simctl list devices available`, then replace
`SIMULATOR_UDID` below with an available iPhone simulator's identifier:

```sh
xcodebuild -workspace SVGAView.xcworkspace -scheme SVGAView \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' test
xcodebuild -workspace SVGAView.xcworkspace -scheme Examples \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' test
```

All configurations target iOS 15.0. Validate minimum-OS runtime behavior on an
iOS 15 device or simulator in addition to building with that deployment target.

## Quick Start

```swift
import SVGAView

let playerView = SVGAView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
playerView.contentMode = .scaleAspectFit
view.addSubview(playerView)

// Play from bundle
playerView.play(named: "animation")

// Or create and load directly
let bannerView = SVGAView(named: "banner")
```

## Usage

### Play from Bundle

```swift
playerView.play(named: "banner")

// From a specific bundle
playerView.play(named: "effect", in: frameworkBundle)

// Initializer form
let playerView = SVGAView(named: "banner", in: frameworkBundle)
```

### Play from URL

```swift
let url = URL(string: "https://cdn.example.com/animation.svga")!
playerView.play(remoteURL: url)

let playerView = SVGAView(remoteURL: url)
```

### Unified Sources

```swift
let source = SVGAViewSource.request(URLRequest(url: url))
playerView.play(source)

try await playerView.load(source, startsPlayback: false)
```

### Preload Without a View

Use `preload(...)` to download, decompress, parse, and cache an SVGA before a player view exists:

```swift
try await SVGAView.preload(remoteURL: url) { progress in
    print("preload progress:", progress)
}

// Later, this reuses the cached entity for the same URL.
playerView.play(remoteURL: url)
```

Concurrent `preload` and `load`/`play` calls for the same URL share the same in-flight request.

All sources are supported:

```swift
try await SVGAView.preload(named: "banner")
try await SVGAView.preload(request: URLRequest(url: url))
try await SVGAView.preload(fileURL: localFileURL)
try await SVGAView.preload(data: svgaData, cacheKey: "gift-v1")
```

### Load Without Auto-Play

Use `load(...)` when you need to await readiness before starting playback:

```swift
try await playerView.load(named: "banner")
playerView.start()

try await playerView.load(remoteURL: url)
try await playerView.load(request: URLRequest(url: url))
try await playerView.load(fileURL: localFileURL)
try await playerView.load(data: svgaData, cacheKey: "gift-v1")
```

You can start playback explicitly from the load call:

```swift
try await playerView.load(.named("banner"), startsPlayback: true)
```

### Additional Play Sources

```swift
playerView.play(request: URLRequest(url: url))
playerView.play(fileURL: localFileURL)
playerView.play(data: svgaData, cacheKey: "gift-v1")
```

### Playback Control

```swift
playerView.start()
playerView.pause()
playerView.stop()

// Play specific frame range
playerView.start(range: 10..<30, reverse: false)

// Jump to a frame
playerView.seek(toFrame: 5, startsPlayback: false)

// Jump to percentage
playerView.seek(toProgress: 0.5, startsPlayback: true)
```

### Dynamic Content

Replace images, text, or add custom drawing to sprites at play time:

```swift
var content = SVGADynamicContent()
content.setImage(avatarImage, forKey: "avatar")
content.setAttributedText(nicknameText, forKey: "username")
content.setHidden(true, forKey: "badge")
content.setDrawingBlock({ layer, frame in
    // custom drawing each frame
}, forKey: "effect")

playerView.play(named: "gift", dynamicContent: content)
```

Or configure dynamic content inline:

```swift
playerView.play(named: "gift") { content in
    content.setImage(avatarImage, forKey: "avatar")
    content.setAttributedText(nicknameText, forKey: "username")
    content.setHidden(true, forKey: "badge")
}

try await playerView.load(.named("gift"), startsPlayback: false) { content in
    content.setHidden(true, forKey: "badge")
}
```

Update dynamic content after the SVGA has loaded:

```swift
playerView.setImage(avatarImage, forKey: "avatar")
playerView.setAttributedText(nicknameText, forKey: "username")
playerView.setHidden(false, forKey: "badge")
playerView.setDrawingBlock({ layer, frame in
    // custom drawing each frame
}, forKey: "effect")

playerView.removeImage(forKey: "avatar")
playerView.removeAttributedText(forKey: "username")
playerView.removeDrawingBlock(forKey: "effect")
playerView.removeHidden(forKey: "badge")
playerView.clearDynamicContent()
```

Image keys may be passed either as the original SVGA `imageKey` or without the file extension.

### Event Callbacks

```swift
playerView.onEvent = { event in
    switch event {
    case .stateChanged(let state):
        print("state changed: \(state)")
    case .ready:
        print("animation is ready")
    case .finished:
        print("animation finished")
    case .frameChanged(let frame):
        print("current frame: \(frame)")
    case .percentageChanged(let percentage):
        print("playback progress: \(percentage)")
    case .downloadProgress(let progress):
        print("download progress: \(progress)")
    case .loadFailed(let error):
        print("load failed: \(error)")
    }
}
```

`SVGAViewEvent` is the single callback surface for loading, playback, frame, percentage, download progress, and failure events.

`state` is exposed as `SVGAViewState` with `idle`, `loading`, `ready`, `playing`, `paused`, `stopped`, and `failed(SVGAViewError)`.

### Cancellation

```swift
playerView.cancelLoading()
playerView.clear()         // also cancels an in-flight load
playerView.stop()          // cancels an in-flight load, or stops playback
```

Starting a new load cancels the previous pending load. Stale completions are ignored.

### Configuration

```swift
playerView.loops = 3              // Play 3 times (0 = infinite, default)
playerView.clearsAfterStop = true // Clear canvas after stop (default true)
playerView.fillMode = .lastFrame  // Stay on last frame after finish
playerView.autoPlay = true        // Auto-play resourcePath loads (default true)
```

### Interface Builder

Set the custom class to `SVGAView` in Interface Builder, then configure:

- **resourcePath** — Bundle resource name, HTTP(S) URL, file URL, or absolute local path
- **autoPlay** — Auto-play on load

`resourcePath` loading is deferred until the view has finished initialization.

## Architecture

```
SVGAView (UIView)
  └── Internal animation engine
        ├── CADisplayLink (frame timing)
        ├── Sprite rendering layers
        │     ├── Bitmap layers
        │     └── Vector shape layers
        ├── Audio sync
        └── SVGA parsing and caching

Public API:
  └── SVGAView and its playback configuration types
```

- **SVGAView** — Public UIView, provides loading, playback, controls, callbacks, and dynamic content.
- Parser, model, renderer, cache, audio, and exporter types are internal implementation details.

## Security

- Path traversal protection on extracted filenames
- Decompression size limits (zlib and ZIP, 100 MB)
- Download size limit (configurable, default 50 MB)
- SHA256 cache keys
- HTTP(S)-only validation for remote URLs; local file URLs use file loading APIs
- Input range clamping (fps, frames, percentages)

## License

MIT

### 异步取消契约（兼容性变更）

`preload` 和异步 `load` 现在以原生 **`CancellationError`** 表示取消，不再向异步调用方抛出 `SVGAViewError.cancelled`。捕获取消的代码应改为：

```swift
let task = Task { try await SVGAView.preload(remoteURL: url) }
task.cancel()
do { try await task.value }
catch is CancellationError { /* 此次加载需求已释放 */ }
```

同 URL 的下载和解析共享底层工作，每次调用拥有独立订阅。仍有其他订阅者时，取消的调用及时结束，其他调用继续；最后一个订阅者取消时，会停止底层下载，等待工作退出及暂存目录清理后返回。随后请求相同 URL 会等待旧实例清理，再开始新实例。解压和解析在阶段边界协作检查取消，不承诺强制中断同步 CPU 工作。

每个实例先在独立暂存目录解压并解析，只有完整资源和已解析实体才会一起提交缓存。实体拥有已读取的图片和音频数据，不保留暂存路径。取消与成功以每个订阅者首先确定的终态为准，已成功的结果不会被迟到取消改写；取消后不再开始进度通知，已执行中的回调可以结束。

直接 `await view.load(...)` 与 `play(...)` 共用视图请求身份管理。调用方 Task 取消、`cancelLoading()`、`clear()` 和替换加载都能释放对应需求。仍为当前请求的直接异步加载取消，会保持 `.failed(.cancelled)` / `.loadFailed(.cancelled)` 状态和事件，同时向调用方抛出 `CancellationError`；被停止或替换的旧请求不会恢复动画、改变新状态或发布迟到事件。预取消不会启动网络或改变视图。
