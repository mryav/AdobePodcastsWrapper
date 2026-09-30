import AppKit
import WebKit

enum EnhancePhase: String {
    case upload, enhance, download
}

struct EnhanceResult {
    let suggestedName: String
    let fileURL: URL
}

enum EnhanceError: LocalizedError {
    case pageFailed(String)
    case automation(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .pageFailed(reason): return "Couldn't reach Adobe Podcast: \(reason)"
        case let .automation(reason): return reason
        case .cancelled: return "Cancelled."
        }
    }
}

/// Owns the hidden WebKit view that talks to podcast.adobe.com.
/// The window stays fully transparent and click-through unless a sign-in is
/// needed, at which point it is revealed so the user can authenticate once.
@MainActor
final class EnhanceSession: NSObject {

    /// ENHANCER_PAGE points the driver at a local mock page for testing the
    /// automation without burning an Adobe conversion.
    static let enhanceURL: URL = {
        if let override = ProcessInfo.processInfo.environment["ENHANCER_PAGE"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://podcast.adobe.com/en/enhance")!
    }()

    private static let localScheme = "enhancerlocal"

    private var webView: WKWebView!
    private var window: NSWindow!
    /// Scratch directory for the current job; the controller swaps this per file.
    var workDirectory: URL

    // Callbacks into the controller.
    var onPhase: ((EnhancePhase) -> Void)?
    var onProgress: ((EnhancePhase, Double) -> Void)?
    var onLog: ((String) -> Void)?
    var onNeedsLogin: (() -> Void)?
    var onLoginFinished: (() -> Void)?

    // Active run state.
    private var continuation: CheckedContinuation<EnhanceResult, Error>?
    private var stagedFile: URL?
    private var stagedMIME: String = "audio/mp4"
    private var isRunning = false
    private var pageIsReady = false
    private var watchdog: Timer?
    private var awaitingSignIn = false

    // Incoming download assembly.
    private var downloadHandle: FileHandle?
    private var downloadURL: URL?
    private var downloadName: String = ""

    init(workDirectory: URL) {
        self.workDirectory = workDirectory
        super.init()
        buildWebView()
    }

    // MARK: - Setup

    private func buildWebView() {
        let controller = WKUserContentController()
        controller.add(self, name: "enhancer")
        controller.addUserScript(WKUserScript(
            source: AutomationScript.load(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()      // keeps the Adobe login between launches
        // podcast.adobe.com blocks custom-scheme fetches from its https origin,
        // so in practice the chunked fallback carries the file. The handler is
        // kept as a fast path (and for the local mock page); ENHANCER_NO_SCHEME
        // disables it so the fallback can be exercised deliberately.
        if ProcessInfo.processInfo.environment["ENHANCER_NO_SCHEME"] == nil {
            configuration.setURLSchemeHandler(self, forURLScheme: Self.localScheme)
        }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
            // Deliberately not closable: if the user dismissed it mid-sign-in
            // there'd be no way back into the flow.
            styleMask: [.titled, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Adobe Podcast"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        applyBrowserVisibility()
    }

    /// Invisible but still "on screen", so WebKit keeps the page active
    /// instead of throttling timers on an occluded window.
    private func conceal() {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    func reveal() {
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideBrowser() {
        if Settings.showBrowser { return }
        conceal()
    }

    func applyBrowserVisibility() {
        Settings.showBrowser ? reveal() : conceal()
    }

    /// Loads the enhance page ahead of time so the first conversion isn't
    /// waiting on a cold page load.
    func warmUp() {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: Self.enhanceURL))
    }

    func shutDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "enhancer")
        window.orderOut(nil)
    }

    // MARK: - Running a file through the site

    func enhance(file: URL, mimeType: String) async throws -> EnhanceResult {
        precondition(!isRunning, "EnhanceSession handles one file at a time")
        isRunning = true
        stagedFile = file
        stagedMIME = mimeType
        defer { isRunning = false; stagedFile = nil }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.pageIsReady = false
            self.awaitingSignIn = false
            self.petWatchdog()
            // Always start from a clean page: a previous run leaves the old
            // result on screen, which would confuse the download-button search.
            self.webView.load(URLRequest(url: Self.enhanceURL))
        }
    }

    func cancel() {
        guard isRunning else { return }
        webView.evaluateJavaScript("window.stop && window.stop()")
        finish(.failure(EnhanceError.cancelled))
    }

    private func finish(_ result: Result<EnhanceResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stopWatchdog()
        closeDownloadHandle()
        continuation.resume(with: result)
    }

    /// The injected script heartbeats while it waits. If those stop — the page
    /// navigated out from under us, or WebKit tore down the JS context — fail
    /// the run instead of leaving the progress bar spinning forever.
    private func petWatchdog() {
        watchdog?.invalidate()
        guard continuation != nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                Log.web("watchdog fired: no activity from the page for 4 minutes")
                self.finish(.failure(EnhanceError.automation(
                    "Lost contact with the Adobe page. Try again, and use Debug → Show Adobe Window to see what it's doing."
                )))
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func startRun() {
        guard let file = stagedFile, continuation != nil, !pageIsReady else { return }
        pageIsReady = true
        let name = file.lastPathComponent
        let url = "\(Self.localScheme)://staged/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "audio")"
        // Wrapped in a function so the completion value is a string: WebKit
        // rejects the Promise that the async runner returns.
        let script = """
        (function () {
            if (!window.__enhancerRun) return "missing";
            window.__enhancerRun(\(jsString(url)), \(jsString(name)), \(jsString(stagedMIME)));
            return "started";
        })()
        """
        Log.web("starting automation for \(name)")
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                self?.finish(.failure(EnhanceError.automation("Automation failed to start: \(error.localizedDescription)")))
            } else if (result as? String) == "missing" {
                self?.finish(.failure(EnhanceError.automation("The automation script didn't load into the page.")))
            }
        }
    }

    private func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())      // strip the array brackets
    }

    // MARK: - Chunked fallback upload

    private func pushFileInChunks() {
        guard let file = stagedFile, let handle = try? FileHandle(forReadingFrom: file) else {
            finish(.failure(EnhanceError.automation("Couldn't read the prepared audio file.")))
            return
        }
        let started = Date()
        Log.web("pushing file to page in chunks")
        Task { @MainActor in
            defer {
                try? handle.close()
                Log.web(String(format: "chunked transfer took %.1fs", Date().timeIntervalSince(started)))
            }
            while true {
                // 768 KB of source per call: big enough that a long podcast is
                // a few hundred hops, small enough not to stall the main thread.
                let chunk = (try? handle.read(upToCount: 768 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                guard continuation != nil else { return }
                let encoded = chunk.base64EncodedString()
                _ = try? await webView.evaluateJavaScript("window.__enhancerPushChunk(\(jsString(encoded)))")
            }
            _ = try? await webView.evaluateJavaScript("window.__enhancerFinishChunks()")
        }
    }

    // MARK: - Assembling the downloaded result

    /// Fetch the result with URLSession rather than relaying it through the
    /// page — far faster, and it keeps big files out of the page's memory.
    private func fetchNatively(_ url: URL, name: String) {
        stopWatchdog()      // URLSession owns the timeouts from here on
        Log.web("downloading natively from \(url.host ?? "?")")
        let referer = webView.url?.absoluteString
        let store = webView.configuration.websiteDataStore.httpCookieStore

        Task { @MainActor in
            let cookies = await store.allCookies()
            let downloader = FileDownloader { [weak self] fraction in
                Task { @MainActor in self?.onProgress?(.download, fraction) }
            }
            do {
                let temporary = try await downloader.download(from: url, cookies: cookies, referer: referer)
                guard self.continuation != nil else {
                    try? FileManager.default.removeItem(at: temporary)
                    return
                }
                let safe = self.sanitize(name.isEmpty ? "enhanced" : name)
                let destination = self.workDirectory.appendingPathComponent(safe)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                self.finish(.success(EnhanceResult(suggestedName: safe, fileURL: destination)))
            } catch {
                self.finish(.failure(EnhanceError.automation("Couldn't download the enhanced file: \(error.localizedDescription)")))
            }
        }
    }

    private func beginDownload(name: String) {
        closeDownloadHandle()
        let safe = sanitize(name)
        let destination = workDirectory.appendingPathComponent(safe.isEmpty ? "enhanced.wav" : safe)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        downloadHandle = try? FileHandle(forWritingTo: destination)
        downloadURL = destination
        downloadName = safe
        Log.web("receiving download as \(safe)")
    }

    private func appendDownload(base64Chunk: String) {
        guard let handle = downloadHandle, let data = Data(base64Encoded: base64Chunk) else { return }
        try? handle.write(contentsOf: data)
    }

    private func completeDownload() {
        closeDownloadHandle()
        guard let url = downloadURL else {
            finish(.failure(EnhanceError.automation("The download finished but produced no data.")))
            return
        }
        downloadURL = nil
        finish(.success(EnhanceResult(suggestedName: downloadName, fileURL: url)))
    }

    private func closeDownloadHandle() {
        try? downloadHandle?.close()
        downloadHandle = nil
    }

    private func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "enhanced.wav" : String(cleaned.prefix(180))
    }
}

// MARK: - Messages from the injected script

extension EnhanceSession: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let payload = body
        Task { @MainActor in self.handle(type: type, payload: payload) }
    }

    @MainActor
    private func handle(type: String, payload: [String: Any]) {
        // Any message at all counts as proof of life, except while we're
        // parked waiting on a human to type their Adobe password.
        if !awaitingSignIn { petWatchdog() } else { stopWatchdog() }

        switch type {
        case "tick":
            break
        case "installed":
            Log.web("automation installed")

        case "log":
            let message = payload["message"] as? String ?? ""
            Log.web(message)
            onLog?(message)

        case "phase":
            guard let raw = payload["phase"] as? String, let phase = EnhancePhase(rawValue: raw) else { return }
            onPhase?(phase)

        case "progress":
            guard let raw = payload["phase"] as? String,
                  let phase = EnhancePhase(rawValue: raw),
                  let value = payload["value"] as? Double else { return }
            onProgress?(phase, value)

        case "needsLogin":
            Log.web("sign-in required; revealing browser")
            awaitingSignIn = true
            stopWatchdog()
            reveal()
            onNeedsLogin?()

        case "loginDone":
            awaitingSignIn = false
            petWatchdog()
            hideBrowser()
            onLoginFinished?()

        case "needChunks":
            pushFileInChunks()

        case "dlUrl":
            guard let raw = payload["url"] as? String, let url = URL(string: raw) else {
                finish(.failure(EnhanceError.automation("Adobe returned a download link the app couldn't read.")))
                return
            }
            fetchNatively(url, name: payload["name"] as? String ?? "")

        case "dlStart":
            beginDownload(name: payload["name"] as? String ?? "")

        case "dlChunk":
            if let chunk = payload["b64"] as? String { appendDownload(base64Chunk: chunk) }

        case "dlEnd":
            completeDownload()

        case "error":
            let message = payload["message"] as? String ?? "Unknown error on the Adobe page."
            Log.web("automation error: \(message)")
            finish(.failure(EnhanceError.automation(message)))

        default:
            break
        }
    }
}

// MARK: - Navigation

extension EnhanceSession: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let url = webView.url
            Log.web("loaded \(url?.absoluteString ?? "?")")
            guard self.continuation != nil else { return }
            // Adobe bounces through auth.services.adobe.com for sign-in; only
            // kick off automation once we're back on the enhance page itself.
            guard let url, url.host == Self.enhanceURL.host else { return }
            self.pageIsReady = false
            self.startRun()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.reportNavigationFailure(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.reportNavigationFailure(error) }
    }

    @MainActor
    private func reportNavigationFailure(_ error: Error) {
        let code = (error as NSError).code
        // -999 is "another navigation superseded this one", which is routine here.
        guard code != NSURLErrorCancelled else { return }
        finish(.failure(EnhanceError.pageFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Task { @MainActor in download.delegate = self }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Task { @MainActor in download.delegate = self }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Keep target="_blank" links (Adobe's help pages) in the same view.
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

// MARK: - WebKit-driven downloads (fallback to the in-page blob capture)

extension EnhanceSession: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        Task { @MainActor in
            let name = self.sanitize(suggestedFilename)
            let destination = self.workDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            self.downloadURL = destination
            self.downloadName = name
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            guard let url = self.downloadURL else { return }
            self.downloadURL = nil
            self.finish(.success(EnhanceResult(suggestedName: self.downloadName, fileURL: url)))
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            self.finish(.failure(EnhanceError.automation("Download failed: \(error.localizedDescription)")))
        }
    }
}

// MARK: - Serving the local audio file to the page

extension EnhanceSession: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        Task { @MainActor in
            guard let requestURL = urlSchemeTask.request.url, let file = self.stagedFile else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            do {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": self.stagedMIME,
                        "Content-Length": String(data.count),
                        "Access-Control-Allow-Origin": "*",
                        "Cache-Control": "no-store",
                    ]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                Log.web("scheme handler failed: \(error.localizedDescription)")
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
