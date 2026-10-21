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
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Screen Recordings", isDirectory: true)

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
                let file = folder.appendingPathComponent("Screen \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).mp4")
                let settings = SCRecordingOutputConfiguration()
                settings.outputURL = file; settings.videoCodecType = .h264; settings.outputFileType = .mp4
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
            self.lastFile = self.pendingFile; self.pendingFile = nil
            self.recording = false; self.busy = false; self.phase = "Saved"
            self.message = "Your recording is ready in Movies → Screen Recordings."
            self.stream = nil; self.output = nil
            if self.quitWhenFinished { NSApp.reply(toApplicationShouldTerminate: true) }
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
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "record.circle").font(.system(size: 48)).foregroundStyle(model.recording ? .red : .accentColor)
            VStack(spacing: 6) {
                Text("Screen Recorder").font(.title2.bold())
                Text("Main screen + computer sound").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Circle().fill(model.recording ? Color.red : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(model.phase).fontWeight(.medium)
                if model.recording { Text(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60)).monospacedDigit() }
            }
            Button(action: { model.recording ? model.stop() : model.start() }) {
                Label(model.recording ? "Stop & Save" : "Start Recording", systemImage: model.recording ? "stop.fill" : "record.circle")
                    .frame(width: 210, height: 28)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            Text(model.message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Recordings") { model.openFolder() }
                if model.phase == "Couldn’t record" {
                    Button("Open Permissions") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    }
                }
                if let file = model.lastFile { Button("Play Latest") { NSWorkspace.shared.open(file) } }
            }
            Text("MP4 · Up to 1920 px wide · 30 fps · Microphone off").font(.caption).foregroundStyle(.tertiary)
        }.padding(30).frame(width: 390)
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
