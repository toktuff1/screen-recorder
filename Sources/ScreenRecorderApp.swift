import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

@MainActor final class RecorderModel: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published var phase = "Ready"
    @Published var message = "Record your main screen with computer sound."
    @Published var busy = false
    @Published var recording = false
    @Published var elapsed = 0
    @Published var lastFile: URL?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var pendingFile: URL?
    private var timer: Timer?
    private var started = Date()
    var quitWhenFinished = false
    @Published var includeVideo = UserDefaults.standard.object(forKey: "includeVideo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeVideo, forKey: "includeVideo") }
    }
    @Published var folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "saveFolder") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Screen Recordings").path, isDirectory: true)
    private var capturedFile: URL?
    private var audioOnly = false

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save recordings"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url; UserDefaults.standard.set(url.path, forKey: "saveFolder")
        }
    }

    func start() {
        guard !busy && !recording else { return }
        busy = true; phase = "Starting…"; message = "Allow screen and audio access if macOS asks."
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No screen is available."])
                }
                // Exclude this app's controls from the recording.
                let apps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = min(1.0, 1920.0 / Double(display.width))
                config.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
                config.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.showsCursor = true; config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000; config.channelCount = 2; config.captureMicrophone = false
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                audioOnly = !includeVideo
                let name = "\(audioOnly ? "Audio" : "Screen") \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
                let file = folder.appendingPathComponent(name + (audioOnly ? ".m4a" : ".mp4"))
                let captureFile = audioOnly ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4") : file
                capturedFile = captureFile
                let settings = SCRecordingOutputConfiguration()
                settings.outputURL = captureFile; settings.videoCodecType = .h264; settings.outputFileType = .mp4
                let sink = SCRecordingOutput(configuration: settings, delegate: self)
                let capture = SCStream(filter: filter, configuration: config, delegate: self)
                try capture.addRecordingOutput(sink)
                pendingFile = file; output = sink; stream = capture
                try await capture.startCapture()
            } catch { fail(error) }
        }
    }
    func stop() {
        guard recording, !busy, let stream else { return }
        busy = true; phase = "Saving…"; timer?.invalidate(); timer = nil
        Task { do { try await stream.stopCapture() } catch { fail(error) } }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.recording = true; self.busy = false; self.phase = "Recording"
            self.message = "Computer sound on · Microphone off"
            self.started = Date(); self.elapsed = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.elapsed = Int(Date().timeIntervalSince(self.started)) }
            }
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.timer?.invalidate(); self.timer = nil
            self.recording = false; self.busy = true; self.phase = "Saving…"
            self.stream = nil; self.output = nil
            do {
                if self.audioOnly, let source = self.capturedFile, let destination = self.pendingFile {
                    let asset = AVURLAsset(url: source)
                    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                        throw NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create audio file. Temporary recording kept at: \(source.path)"])
                    }
                    try await exporter.export(to: destination, as: .m4a)
                    try? FileManager.default.removeItem(at: source)
                }
                self.lastFile = self.pendingFile; self.pendingFile = nil; self.capturedFile = nil
                self.busy = false; self.phase = "Saved"
                self.message = "Saved to \(self.folder.path)"
                if self.quitWhenFinished { NSApp.reply(toApplicationShouldTerminate: true) }
            } catch { self.fail(error) }
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }
    private func fail(_ error: Error) {
        timer?.invalidate(); timer = nil; recording = false; busy = false
        phase = "Couldn’t record"
        message = error.localizedDescription + " If access was denied, allow Screen Recorder in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."
        stream = nil; output = nil
        if quitWhenFinished { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RecorderModel()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.busy && !model.recording { return .terminateCancel }
        if model.recording {
            model.quitWhenFinished = true
            if !model.busy { model.stop() }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    private var folderLabel: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return model.folder.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
    }
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                if let icon = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "")) {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recorder").font(.system(size: 22, weight: .semibold))
                    Text("Capture a moment. Keep the sound.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECORDING").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    Picker("Recording mode", selection: $model.includeVideo) {
                        Text("Screen & Audio").tag(true)
                        Text("Audio Only").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
                    Text(model.includeVideo ? "Main display and computer sound · MP4" : "Computer sound without video · M4A")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.folder.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(folderLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.help(model.folder.path)
                    Spacer(minLength: 8)
                    Button("Choose…") { model.chooseFolder() }.fixedSize()
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            .disabled(model.recording || model.busy)
            VStack(spacing: 14) {
                HStack(spacing: 7) {
                    Circle().fill(model.recording ? Color.red : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(model.phase).font(.callout.weight(.medium))
                    if model.recording {
                        Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60)).monospacedDigit().font(.callout)
                    }
                }.frame(height: 18)
                Button(action: { model.recording ? model.stop() : model.start() }) {
                    Label(model.recording ? "Stop & Save" : "Start Recording", systemImage: model.recording ? "stop.fill" : "record.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                }.buttonStyle(.borderedProminent).controlSize(.large).tint(model.recording ? .red : .accentColor).disabled(model.busy)
                if model.phase == "Couldn’t record" {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Open Permissions") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            HStack {
                Button(action: { model.openFolder() }) { Label("Recordings", systemImage: "folder") }
                Spacer()
                if let file = model.lastFile {
                    Button(action: { NSWorkspace.shared.open(file) }) { Label("Play Latest", systemImage: "play.circle") }
                } else {
                    Label("Microphone off", systemImage: "mic.slash").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless).font(.callout)
        }
        .padding(28).frame(width: 420)
    }
}
@main struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { RecorderView(model: delegate.model) }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
