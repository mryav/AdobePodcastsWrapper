import Foundation

struct MediaInfo {
    var duration: Double        // seconds; 0 when unknown
    var hasVideo: Bool
    var hasAudio: Bool
}

enum MediaError: LocalizedError {
    case ffmpegNotFound
    case noAudioTrack
    case toolFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg wasn't found. Install it (brew install ffmpeg) or point the app at it from the ⚙ menu."
        case .noAudioTrack:
            return "That file has no audio track to enhance."
        case let .toolFailed(tool, code, tail):
            return "\(tool) exited with code \(code).\n\(tail)"
        }
    }
}

enum FFmpeg {

    // MARK: - Locating the binaries

    private static let searchDirectories = [
        "/opt/homebrew/bin",    // Apple silicon Homebrew
        "/usr/local/bin",       // Intel Homebrew / manual installs
        "/opt/local/bin",       // MacPorts
        "/usr/bin",
    ]

    static func locate(_ tool: String) -> URL? {
        // A binary shipped inside the .app always wins.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: tool),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if tool == "ffmpeg", let custom = Settings.ffmpegPath, !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        // ffprobe normally sits next to a hand-picked ffmpeg.
        if tool == "ffprobe", let custom = Settings.ffmpegPath, !custom.isEmpty {
            let sibling = URL(fileURLWithPath: custom).deletingLastPathComponent()
                .appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        for dir in searchDirectories {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        // Last resort: ask the login shell, which knows about custom PATH entries.
        if let fromShell = viaLoginShell(tool) { return fromShell }
        return nil
    }

    private static func viaLoginShell(_ tool: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var isAvailable: Bool { locate("ffmpeg") != nil }

    // MARK: - Probing

    static func probe(_ url: URL) -> MediaInfo {
        guard let ffprobe = locate("ffprobe") else {
            // Without ffprobe, assume the worst (has video) so we still extract.
            return MediaInfo(duration: 0, hasVideo: true, hasAudio: true)
        }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", url.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return MediaInfo(duration: 0, hasVideo: true, hasAudio: true)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MediaInfo(duration: 0, hasVideo: true, hasAudio: true)
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let hasVideo = streams.contains { stream in
            guard (stream["codec_type"] as? String) == "video" else { return false }
            // Cover art embedded in an mp3 is a video stream; don't treat it as one.
            let disposition = stream["disposition"] as? [String: Any] ?? [:]
            return (disposition["attached_pic"] as? Int ?? 0) == 0
        }
        let hasAudio = streams.contains { ($0["codec_type"] as? String) == "audio" }
        let format = root["format"] as? [String: Any] ?? [:]
        let duration = Double(format["duration"] as? String ?? "") ?? 0

        Log.media("probe \(url.lastPathComponent): duration=\(duration) video=\(hasVideo) audio=\(hasAudio)")
        return MediaInfo(duration: duration, hasVideo: hasVideo, hasAudio: hasAudio)
    }

    // MARK: - Extraction

    /// Formats podcast.adobe.com's file input accepts verbatim.
    static let acceptedExtensions: Set<String> = ["mp3", "wav", "aac", "flac", "oga", "ogg", "m4a"]

    /// Adobe rejects uploads past this size, so anything larger gets re-encoded.
    static let maxUploadBytes: Int64 = 450 * 1024 * 1024

    /// True when the file can be handed to Adobe untouched.
    static func canUploadDirectly(_ url: URL, info: MediaInfo) -> Bool {
        guard !info.hasVideo, info.hasAudio else { return false }
        guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return size <= maxUploadBytes
    }

    /// Strips video (or re-encodes oversized audio) into an .m4a Adobe will accept.
    /// `onProgress` receives 0...1 based on ffmpeg's reported timestamp.
    static func extractAudio(
        from source: URL,
        to destination: URL,
        duration: Double,
        isCancelled: @escaping () -> Bool,
        onProgress: @escaping (Double) -> Void
    ) throws {
        guard let ffmpeg = locate("ffmpeg") else { throw MediaError.ffmpegNotFound }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", source.path,
            "-vn", "-sn", "-dn",              // drop video, subtitles, data
            "-map", "0:a:0",                  // first audio track only
            "-ac", "2", "-ar", "48000",
            "-c:a", "aac", "-b:a", "192k",
            destination.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        Log.media("ffmpeg \(process.arguments!.joined(separator: " "))")
        try process.run()

        // ffmpeg writes "time=00:01:23.45" progress lines to stderr.
        var tail = ""
        let handle = errPipe.fileHandleForReading
        var buffer = ""
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if isCancelled() {
                process.terminate()
                break
            }
            buffer += String(decoding: chunk, as: UTF8.self)
            // Progress lines are \r-separated; keep only the last partial fragment.
            let parts = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            buffer = parts.last ?? ""
            for part in parts.dropLast() {
                tail = part
                if duration > 0, let seconds = parseTimestamp(in: part) {
                    onProgress(min(1, max(0, seconds / duration)))
                }
            }
        }
        process.waitUntilExit()

        if isCancelled() { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw MediaError.toolFailed("ffmpeg", process.terminationStatus, String(tail.suffix(600)))
        }
        onProgress(1)
    }

    private static func parseTimestamp(in line: String) -> Double? {
        guard let range = line.range(of: "time=") else { return nil }
        let rest = line[range.upperBound...].prefix(11)   // HH:MM:SS.ss
        let fields = rest.split(separator: ":")
        guard fields.count == 3,
              let hours = Double(fields[0]),
              let minutes = Double(fields[1]),
              let seconds = Double(fields[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
