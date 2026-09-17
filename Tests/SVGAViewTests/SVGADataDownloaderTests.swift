import Foundation
import Testing
@testable import SVGAView

private actor DownloadOutcome {
    var result: Result<Data, Error>?

    func record(_ result: Result<Data, Error>) {
        self.result = result
    }
}

private final class DownloaderURLProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 0x42, count: 65_536)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "downloader.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if request.url?.path == "/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: request.url?.path == "/unknown-length" ? nil : ["Content-Length": "\(Self.payload.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/pending" {
            client?.urlProtocol(self, didLoad: Data(Self.payload.prefix(Self.payload.count / 2)))
            return
        }
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func downloadRequest(path: String = "success") -> URLRequest {
    URLRequest(
        url: URL(string: "https://downloader.test/\(path)")!,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 5
    )
}

private func downloadConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloaderURLProtocol.self]
    return configuration
}

// A bounded observation avoids hanging the test runner if a continuation is leaked.
private func waitForOutcome(_ outcome: DownloadOutcome) async throws -> Result<Data, Error>? {
    for _ in 0..<300 {
        if let result = await outcome.result { return result }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return await outcome.result
}


// Hold the final data callback until cancellation and completion can be released together.
// The timeout and deferred signals keep a failed assertion from blocking a delegate queue.
private func raceCancellationAgainstCompletion() async throws {
    let outcome = DownloadOutcome()
    let progress = ProgressRecorder()
    let releaseCompletion = DispatchSemaphore(value: 0)
    let task = Task.detached {
        do {
            let data = try await SVGADataDownloader.download(
                request: downloadRequest(),
                maximumSize: DownloaderURLProtocol.payload.count,
                progressHandler: { value in
                    progress.record(value)
                    if value == 1.0 {
                        _ = releaseCompletion.wait(timeout: .now() + 5)
                    }
                },
                configuration: downloadConfiguration()
            )
            await outcome.record(.success(data))
        } catch {
            await outcome.record(.failure(error))
        }
    }
    defer {
        releaseCompletion.signal()
        releaseCompletion.signal()
        task.cancel()
    }

    for _ in 0..<300 where !progress.values.contains(1.0) {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(progress.values.contains(1.0), "The download must reach its final data callback before racing cancellation")
    let cancellation = Task.detached { task.cancel() }
    // Progress can reach 1.0 both in didReceive data and didCompleteWithError.
    releaseCompletion.signal()
    releaseCompletion.signal()
    await cancellation.value

    switch try await waitForOutcome(outcome) {
    case .success(let data):
        #expect(data == DownloaderURLProtocol.payload)
    case .failure(let error):
        #expect(error is CancellationError)
    case nil:
        Issue.record("Cancellation racing completion left the download suspended")
    }
}

@Suite
struct SVGADataDownloaderTests {
    @Test
    func cancellationBeforeStartCompletes() async throws {
        let outcome = DownloadOutcome()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let data = try await SVGADataDownloader.download(
                    request: downloadRequest(),
                    maximumSize: DownloaderURLProtocol.payload.count,
                    progressHandler: nil,
                    configuration: downloadConfiguration()
                )
                await outcome.record(.success(data))
            } catch {
                await outcome.record(.failure(error))
            }
        }
        defer { task.cancel() }

        let result = try await waitForOutcome(outcome)
        guard case .failure(let error) = result else {
            Issue.record("An already-cancelled download must finish with CancellationError; got \(String(describing: result))")
            return
        }
        #expect(error is CancellationError)
    }

    @Test
    func cancellationDuringDownloadCompletes() async throws {
        let outcome = DownloadOutcome()
        let progress = ProgressRecorder()
        let task = Task.detached {
            do {
                let data = try await SVGADataDownloader.download(
                    request: downloadRequest(path: "pending"),
                    maximumSize: DownloaderURLProtocol.payload.count,
                    progressHandler: { progress.record($0) },
                    configuration: downloadConfiguration()
                )
                await outcome.record(.success(data))
            } catch {
                await outcome.record(.failure(error))
            }
        }
        defer { task.cancel() }

        for _ in 0..<300 where !progress.values.contains(0.5) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(progress.values.contains(0.5))
        task.cancel()

        let result = try await waitForOutcome(outcome)
        guard case .failure(let error) = result else {
            Issue.record("A pending download must finish after cancellation; got \(String(describing: result))")
            return
        }
        #expect(error is CancellationError)
        #expect(!progress.values.contains(1.0))
    }

    @Test
    func cancellationRacingCompletionFinishesOnce() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<8 {
                        try await raceCancellationAgainstCompletion()
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test
    func successfulDownloadPreservesDataAndProgress() async throws {
        let progress = ProgressRecorder()
        let data = try await SVGADataDownloader.download(
            request: downloadRequest(),
            maximumSize: DownloaderURLProtocol.payload.count,
            progressHandler: { progress.record($0) },
            configuration: downloadConfiguration()
        )
        #expect(data == DownloaderURLProtocol.payload)
        #expect(progress.values.first == 0.0)
        #expect(progress.values.last == 1.0)
    }

    @Test(arguments: ["success", "unknown-length"])
    func oversizedDownloadStillFails(path: String) async throws {
        do {
            _ = try await SVGADataDownloader.download(
                request: downloadRequest(path: path),
                maximumSize: DownloaderURLProtocol.payload.count - 1,
                progressHandler: nil,
                configuration: downloadConfiguration()
            )
            Issue.record("Expected the declared or streamed size limit to reject the download")
        } catch SVGAParserError.fileTooLarge {
            // Both Content-Length and actual received bytes must enforce the limit.
        }
    }

    @Test
    func transportFailurePreservesError() async throws {
        do {
            _ = try await SVGADataDownloader.download(
                request: downloadRequest(path: "failure"),
                maximumSize: DownloaderURLProtocol.payload.count,
                progressHandler: nil,
                configuration: downloadConfiguration()
            )
            Issue.record("Expected the transport error to reach the caller")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
    }
}
