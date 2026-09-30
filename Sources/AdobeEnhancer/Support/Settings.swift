import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Explicit ffmpeg location, set from the UI when auto-discovery fails.
    static var ffmpegPath: String? {
        get { defaults.string(forKey: "ffmpegPath") }
        set { defaults.set(newValue, forKey: "ffmpegPath") }
    }

    /// Show the Adobe web view instead of keeping it invisible. Debug aid.
    static var showBrowser: Bool {
        get { defaults.bool(forKey: "showBrowser") }
        set { defaults.set(newValue, forKey: "showBrowser") }
    }

    /// Suffix appended to the original basename for the enhanced result.
    static var outputSuffix: String {
        get { defaults.string(forKey: "outputSuffix") ?? " (enhanced)" }
        set { defaults.set(newValue, forKey: "outputSuffix") }
    }
}
