import AppKit
import Combine
import Foundation

/// Thread-safe cancel flag shared with the ffmpeg worker thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

@MainActor
final class ConversionController: ObservableObject {

    enum Stage: Equatable {
        case idle, preparing, uploading, enhancing, downloading, finished, failed

        var isBusy: Bool {
            switch self {
            case .preparing, .uploading, .enhancing, .downloading: return true
            default: return false
            }
        }

        var detail: String {
            switch self {
            case .idle: return ""
            case .preparing: return "Preparing audio"
            case .uploading: return "Uploading"
            case .enhancing: return "Enhancing"
            case .downloading: return "Saving"
            case .finished: return "Done"
            case .failed: return "Failed"
            }
        }
    }

    // Each stage owns a slice of the single progress bar the user sees.
    private static let weights: [Stage: ClosedRange<Double>] = [
        .preparing: 0.00...0.25,
        .uploading: 0.25...0.40,
        .enhancing: 0.40...0.92,
        .downloading: 0.92...1.00,
    ]

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var sourceName = ""
    @Published private(set) var queueLabel = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var waitingForSignIn = false
    @Published private(set) var results: [URL] = []
    @Published private(set) var ffmpegMissing = !FFmpeg.isAvailable

    private var session: EnhanceSession?
    private let cancelFlag = CancelFlag()
    private var task: Task<Void, Never>?
    private var enhanceRamp: Timer?
    private var enhanceReported: Double = 0
    private var enhanceRampValue: Double = 0

    // MARK: - Lifecycle

    func prepareSession() {
        let session = makeSessionIfNeeded()
        session.warmUp()
    }

    func teardown() {
        session?.shutDown()
    }

    private func makeSessionIfNeeded() -> EnhanceSession {
        if let session { return session }
        let workDirectory = (try? AppPaths.makeWorkDirectory()) ?? FileManager.default.temporaryDirectory
        let session = EnhanceSession(workDirectory: workDirectory)
        session.onPhase = { [weak self] phase in self?.enterPhase(phase) }
        session.onProgress = { [weak self] phase, value in self?.updatePhase(phase, value: value) }
        session.onNeedsLogin = { [weak self] in self?.waitingForSignIn = true }
        session.onLoginFinished = { [weak self] in self?.waitingForSignIn = false }
        self.session = session
        return session
    }

    // MARK: - Public actions

    func start(files: [URL]) {
        guard !files.isEmpty, !stage.isBusy else { return }
        let audioVideo = files.filter { !$0.hasDirectoryPath }
        guard !audioVideo.isEmpty else { return }

        errorMessage = nil
        results = []
        cancelFlag.reset()
        task = Task { await self.run(queue: audioVideo) }
    }

    func cancel() {
        cancelFlag.set()
        session?.cancel()
        task?.cancel()
        stopRamp()
        stage = .idle
        progress = 0
        queueLabel = ""
    }

    func reset() {
        guard !stage.isBusy else { return }
        stage = .idle
        progress = 0
        errorMessage = nil
        results = []
        sourceName = ""
        queueLabel = ""
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func toggleBrowserVisibility() {
        Settings.showBrowser.toggle()
        session?.applyBrowserVisibility()
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.title = "Locate ffmpeg"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.ffmpegPath = url.path
        ffmpegMissing = !FFmpeg.isAvailable
    }

    // MARK: - Pipeline

    private func run(queue: [URL]) async {
        for (index, source) in queue.enumerated() {
            guard !cancelFlag.isSet else { break }
            sourceName = source.lastPathComponent
            queueLabel = queue.count > 1 ? "File \(index + 1) of \(queue.count)" : ""
            progress = 0
            do {
                let output = try await convert(source)
                results.append(output)
            } catch is CancellationError {
                stage = .idle
                progress = 0
                return
            } catch EnhanceError.cancelled {
                stage = .idle
                progress = 0
                return
            } catch {
                stopRamp()
                stage = .failed
                errorMessage = error.localizedDescription
                Log.write("failed: \(error.localizedDescription)")
                return
            }
        }
        stopRamp()
        progress = 1
        stage = results.isEmpty ? .idle : .finished
        queueLabel = ""
    }

    private func convert(_ source: URL) async throws -> URL {
        let workDirectory = try AppPaths.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        // 1. Strip video / normalise so Adobe's uploader will accept the file.
        setStage(.preparing, fraction: 0)
        let info = FFmpeg.probe(source)
        guard info.hasAudio else { throw MediaError.noAudioTrack }

        let upload: URL
        let mime: String
        if FFmpeg.canUploadDirectly(source, info: info) {
            upload = source
            mime = mimeType(for: source.pathExtension.lowercased())
            setStage(.preparing, fraction: 1)
        } else {
            guard FFmpeg.isAvailable else { throw MediaError.ffmpegNotFound }
            let base = source.deletingPathExtension().lastPathComponent
            let destination = workDirectory.appendingPathComponent(base + ".m4a")
            try await extractAudio(from: source, to: destination, duration: info.duration)
            upload = destination
            mime = "audio/mp4"
        }
        try Task.checkCancellation()

        // 2. Hand it to podcast.adobe.com and wait for the enhanced result.
        let session = makeSessionIfNeeded()
        session.workDirectory = workDirectory
        setStage(.uploading, fraction: 0)
        beginRamp(expectedSeconds: max(20, info.duration * 0.6))
        let result = try await session.enhance(file: upload, mimeType: mime)
        stopRamp()

        // 3. Drop the enhanced audio next to the file the user gave us.
        setStage(.downloading, fraction: 0.8)
        let output = try place(result, nextTo: source)
        setStage(.downloading, fraction: 1)
        Log.write("wrote \(output.path)")
        return output
    }

    private func extractAudio(from source: URL, to destination: URL, duration: Double) async throws {
        let flag = cancelFlag
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FFmpeg.extractAudio(
                        from: source,
                        to: destination,
                        duration: duration,
                        isCancelled: { flag.isSet },
                        onProgress: { fraction in
                            Task { @MainActor in self.setStage(.preparing, fraction: fraction) }
                        }
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func place(_ result: EnhanceResult, nextTo source: URL) throws -> URL {
        let directory = source.deletingLastPathComponent()
        // Adobe serves the result as "premixed" with no extension, so fall back
        // to sniffing the container rather than guessing.
        var ext = URL(fileURLWithPath: result.suggestedName).pathExtension.lowercased()
        if ext.isEmpty { ext = result.fileURL.pathExtension.lowercased() }
        if ext.isEmpty { ext = Self.sniffExtension(of: result.fileURL) }
        let base = source.deletingPathExtension().lastPathComponent + Settings.outputSuffix

        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: result.fileURL, to: candidate)
        } catch {
            // Different volume, or the work dir is being cleaned up: copy instead.
            try FileManager.default.copyItem(at: result.fileURL, to: candidate)
        }
        return candidate
    }

    /// Identifies the container from its magic number.
    private static func sniffExtension(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "wav" }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 12)) ?? Data()
        guard header.count >= 12 else { return "wav" }
        let bytes = [UInt8](header)

        func matches(_ ascii: String, at offset: Int) -> Bool {
            let pattern = [UInt8](ascii.utf8)
            guard offset + pattern.count <= bytes.count else { return false }
            return Array(bytes[offset ..< offset + pattern.count]) == pattern
        }

        if matches("RIFF", at: 0), matches("WAVE", at: 8) { return "wav" }
        if matches("ftyp", at: 4) { return "m4a" }
        if matches("OggS", at: 0) { return "ogg" }
        if matches("fLaC", at: 0) { return "flac" }
        if matches("ID3", at: 0) { return "mp3" }
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "mp3" }
        return "wav"
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "oga": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Progress plumbing

    private func setStage(_ stage: Stage, fraction: Double) {
        self.stage = stage
        guard let range = Self.weights[stage] else { return }
        let value = range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, fraction))
        progress = max(progress, value)     // the bar never walks backwards
    }

    private func enterPhase(_ phase: EnhancePhase) {
        switch phase {
        case .upload: setStage(.uploading, fraction: 0)
        case .enhance: setStage(.enhancing, fraction: 0)
        case .download: stopRamp(); setStage(.downloading, fraction: 0)
        }
    }

    private func updatePhase(_ phase: EnhancePhase, value: Double) {
        switch phase {
        case .upload:
            setStage(.uploading, fraction: value)
        case .enhance:
            enhanceReported = max(enhanceReported, value)
            setStage(.enhancing, fraction: max(enhanceReported, enhanceRampValue))
        case .download:
            setStage(.downloading, fraction: value)
        }
    }

    /// Adobe doesn't always publish a percentage, so the bar is also driven by
    /// an asymptotic estimate based on the clip's duration. Whichever is
    /// further along wins, and the bar never claims to be finished early.
    private func beginRamp(expectedSeconds: Double) {
        stopRamp()
        enhanceReported = 0
        enhanceRampValue = 0
        let started = Date()
        enhanceRamp = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.stage == .enhancing || self.stage == .uploading else { return }
                let elapsed = Date().timeIntervalSince(started)
                self.enhanceRampValue = min(0.95, 1 - exp(-elapsed / max(1, expectedSeconds)))
                if self.stage == .enhancing {
                    self.setStage(.enhancing, fraction: max(self.enhanceReported, self.enhanceRampValue))
                }
            }
        }
    }

    private func stopRamp() {
        enhanceRamp?.invalidate()
        enhanceRamp = nil
    }
}
