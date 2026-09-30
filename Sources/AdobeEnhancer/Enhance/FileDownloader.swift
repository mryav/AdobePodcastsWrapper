import Foundation

/// Pulls the finished audio straight off Adobe's CDN instead of relaying it
/// through the page. Carries the web view's cookies in case the link isn't
/// presigned, and reports byte progress so the bar keeps moving on big files.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void
    private var session: URLSession?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func download(from url: URL, cookies: [HTTPCookie], referer: String?) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted as soon as this method returns, so move it now.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhancer-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            resume(.success(destination))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resume(.failure(error)) }
    }

    private func resume(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
