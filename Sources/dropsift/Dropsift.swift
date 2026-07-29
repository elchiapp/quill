import AppKit
import ArgumentParser
import Foundation

@main
struct Dropsift: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dropsift",
        abstract: "Private local meeting workspace with recording, transcription, and local-AI chat.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Open the Dropsift desktop app (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let controller = AppController(root: root)
        app.delegate = controller

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "dropsift up · iCloud library → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private let menuBar = MenuBarController()
    private lazy var mainWindow = DropsiftWindowController(model: model)

    init(root: URL) {
        model = AppModel(root: root)
        super.init()

        menuBar.onShow = { [weak self] in self?.showWindow() }
        menuBar.onToggle = { [weak self] in self?.model.toggleRecording() }
        menuBar.onOpenFolder = { [weak self] in self?.model.openRecordingsFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        model.onRecordingStateChange = { [weak self] recording, elapsed in
            self?.menuBar.update(recording: recording, elapsed: elapsed)
        }
        model.onTranscriptionStateChange = { [weak self] status in
            self?.menuBar.updateTranscription(status)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startServices()
        showWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func showWindow() {
        mainWindow.showWindow(nil)
        mainWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        model.shutdown()
        NSApp.terminate(nil)
    }
}
