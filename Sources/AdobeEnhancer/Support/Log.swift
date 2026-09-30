import Foundation

/// Tiny append-only logger. Everything the automation does ends up here so a
/// broken run can be diagnosed without attaching a debugger.
enum Log {
    static let fileURL: URL = {
        let dir = AppPaths.supportDirectory
        return dir.appendingPathComponent("enhancer.log")
    }()

    private static let queue = DispatchQueue(label: "enhancer.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String, category: String = "app") {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func web(_ message: String) { write(message, category: "web") }
    static func media(_ message: String) { write(message, category: "media") }
}

enum AppPaths {
    /// ~/Library/Application Support/AdobeEnhancer
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AdobeEnhancer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Scratch space for extracted audio and in-flight downloads.
    static func makeWorkDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdobeEnhancer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Optional user-supplied override for the injected automation script.
    /// Selectors on podcast.adobe.com change; this lets them be patched without a rebuild.
    static var automationOverride: URL {
        supportDirectory.appendingPathComponent("automation.js")
    }
}
