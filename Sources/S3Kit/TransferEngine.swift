import Foundation

/// Progress callback: bytes transferred so far and the expected total (`-1` if unknown).
public typealias TransferProgress = @Sendable (_ completed: Int64, _ total: Int64) -> Void

/// Runs uploads and downloads on a delegate-based URLSession so that byte-level
/// progress is reported, and exposes them as async functions.
final class TransferEngine: NSObject, @unchecked Sendable {
    static let shared = TransferEngine()

    private final class TaskState {
        var progress: TransferProgress?
        var body = Data()
        var destination: URL?
        var fileError: Error?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "S3Kit.TransferEngine"
        return queue
    }()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    /// Uploads a file or in-memory body. Returns the response body and headers.
    func upload(_ request: URLRequest, fromFile file: URL? = nil, data: Data? = nil, progress: TransferProgress?) async throws -> (Data, HTTPURLResponse) {
        try await run(progress: progress, destination: nil) { session in
            if let file {
                return session.uploadTask(with: request, fromFile: file)
            }
            return session.uploadTask(with: request, from: data ?? Data())
        }
    }

    /// Downloads to `destination`, replacing any file already there. On an error status
    /// nothing is written and the error document is returned in the thrown `S3Error`.
    func download(_ request: URLRequest, to destination: URL, progress: TransferProgress?) async throws -> HTTPURLResponse {
        let (data, response) = try await run(progress: progress, destination: destination) { session in
            session.downloadTask(with: request)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw S3Error.from(status: response.statusCode, data: data)
        }
        return response
    }

    private func run(progress: TransferProgress?, destination: URL?, makeTask: (URLSession) -> URLSessionTask) async throws -> (Data, HTTPURLResponse) {
        let task = makeTask(session)
        let state = TaskState()
        state.progress = progress
        state.destination = destination

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.continuation = continuation
                lock.withLock { states[task.taskIdentifier] = state }
                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func state(for task: URLSessionTask) -> TaskState? {
        lock.withLock { states[task.taskIdentifier] }
    }
}

extension TransferEngine: URLSessionDataDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        state(for: task)?.progress?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state(for: dataTask)?.body.append(data)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        state(for: downloadTask)?.progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let state = self.state(for: downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // The temporary file is deleted when this method returns, so it has to be handled here.
        if (200..<300).contains(status), let destination = state.destination {
            do {
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: location, to: destination)
            } catch {
                state.fileError = error
            }
        } else {
            state.body = (try? Data(contentsOf: location)) ?? Data()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock { states.removeValue(forKey: task.taskIdentifier) }
        guard let state, let continuation = state.continuation else { return }
        if let error = error ?? state.fileError {
            continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            continuation.resume(returning: (state.body, response))
        } else {
            continuation.resume(throwing: S3Error.invalidResponse("No HTTP response"))
        }
    }
}
