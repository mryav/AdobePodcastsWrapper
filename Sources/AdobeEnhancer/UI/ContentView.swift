import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var controller: ConversionController
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            switch controller.stage {
            case .idle:
                dropZone
            case .finished:
                finishedView
            case .failed:
                failureView
            default:
                progressView
            }
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            accept(urls)
        } isTargeted: { targeted in
            isTargeted = targeted && !controller.stage.isBusy
        }
    }

    // MARK: - Idle

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)

            Text("Drop or paste an audio or video file")
                .font(.title3.weight(.medium))

            Text("⌘V to paste  ·  ⌘O to browse")
                .font(.callout)
                .foregroundStyle(.secondary)

            if controller.ffmpegMissing {
                VStack(spacing: 6) {
                    Label("ffmpeg not found — video files can't be converted", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Locate ffmpeg…") { controller.chooseFFmpeg() }
                        .buttonStyle(.link)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    // MARK: - Working

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.sourceName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("Converting, \(Int(controller.progress * 100))% finished")
                .font(.title3.weight(.medium))
                .monospacedDigit()

            ProgressView(value: controller.progress)
                .progressViewStyle(.linear)

            HStack {
                Text(controller.waitingForSignIn ? "Waiting for you to sign in…" : controller.stage.detail)
                    .font(.caption)
                    .foregroundStyle(controller.waitingForSignIn ? Color.orange : Color.secondary)
                if !controller.queueLabel.isEmpty {
                    Text("· \(controller.queueLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Result

    private var finishedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text(controller.results.count == 1 ? "Enhanced audio saved" : "\(controller.results.count) files saved")
                .font(.title3.weight(.medium))

            VStack(spacing: 6) {
                ForEach(controller.results, id: \.self) { url in
                    Button {
                        controller.reveal(url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "music.note")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                    .contextMenu {
                        Button("Show in Finder") { controller.reveal(url) }
                        Button("Play") { controller.open(url) }
                    }
                }
            }

            Button("Convert another") { controller.reset() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var failureView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Couldn't finish")
                .font(.title3.weight(.medium))
            ScrollView {
                Text(controller.errorMessage ?? "Unknown error.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 90)
            Button("Try again") { controller.reset() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Input

    @discardableResult
    private func accept(_ urls: [URL]) -> Bool {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty, !controller.stage.isBusy else { return false }
        controller.reset()
        controller.start(files: files)
        return true
    }
}
