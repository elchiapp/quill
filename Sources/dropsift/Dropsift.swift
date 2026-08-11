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
    private let meetingNotifications = MeetingNotificationController()
    private var meetingAutoStop = MeetingRecordingAutoStopState()
    private lazy var mainWindow = DropsiftWindowController(model: model)

    init(root: URL) {
        model = AppModel(root: root)
        super.init()

        menuBar.onShow = { [weak self] in self?.showWindow() }
        menuBar.onToggle = { [weak self] in self?.model.toggleRecording() }
        menuBar.onOpenFolder = { [weak self] in self?.model.openRecordingsFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)
        meetingNotifications.onStartRecording = { [weak self] meeting in
            guard let self, !self.model.isRecording else { return }
            self.meetingAutoStop.meetingDetected(meeting)
            self.model.startRecording()
            self.showWindow()
        }
        model.onMeetingDetected = { [weak self] meeting in
            guard let self else { return }
            self.meetingAutoStop.meetingDetected(meeting)
            if !self.model.isRecording {
                self.meetingNotifications.proposeRecording(for: meeting)
            }
        }
        model.onMeetingEnded = { [weak self] meeting in
            guard let self else { return }
            let shouldStop = self.meetingAutoStop.meetingEnded(meeting)
            guard self.model.isRecording, shouldStop else { return }
            self.model.stopRecording()
            self.meetingNotifications.reportAutomaticallyStopped(for: meeting)
        }

        model.onRecordingStateChange = { [weak self] recording, elapsed in
            self?.menuBar.update(recording: recording, elapsed: elapsed)
            if recording {
                self?.meetingAutoStop.recordingStarted()
            } else {
                self?.meetingAutoStop.recordingStopped()
            }
        }
        model.onTranscriptionStateChange = { [weak self] status in
            self?.menuBar.updateTranscription(status)
        }

        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        meetingNotifications.configure()
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

    @objc private func showSettingsFromMenu(_ sender: Any?) {
        showWindow()
        model.showingSettings = true
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        shutdown()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationMenu = NSMenu(title: "Dropsift")
        let applicationMenuItem = NSMenuItem(title: "Dropsift", action: nil, keyEquivalent: "")
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let about = NSMenuItem(
            title: "About Dropsift",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        applicationMenu.addItem(services)
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Hide Dropsift",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        applicationMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        applicationMenu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = NSApp
        applicationMenu.addItem(showAll)
        applicationMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Dropsift",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        applicationMenu.addItem(quit)

        let fileMenu = NSMenu(title: "File")
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        fileMenu.addItem(
            NSMenuItem(
                title: "Close Window",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
        )

        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        editMenu.addItem(
            NSMenuItem(
                title: "Undo",
                action: Selector(("undo:")),
                keyEquivalent: "z"
            )
        )
        let redo = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(
                title: "Cut",
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x"
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Copy",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c"
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
        )
        editMenu.addItem(
            NSMenuItem(
                title: "Select All",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a"
            )
        )

        let viewMenu = NSMenu(title: "View")
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)

        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenu.addItem(
            NSMenuItem(
                title: "Zoom",
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""
            )
        )
        windowMenu.addItem(.separator())
        let bringAllToFront = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAllToFront.target = NSApp
        windowMenu.addItem(bringAllToFront)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

struct MeetingRecordingAutoStopState: Sendable {
    private(set) var detectedMeetingBundleID: String?
    private(set) var recordingMeetingBundleID: String?

    mutating func meetingDetected(_ meeting: DetectedMeeting) {
        detectedMeetingBundleID = meeting.bundleID
        if recordingMeetingBundleID != nil {
            recordingMeetingBundleID = meeting.bundleID
        }
    }

    mutating func recordingStarted() {
        recordingMeetingBundleID = detectedMeetingBundleID
    }

    mutating func recordingStopped() {
        recordingMeetingBundleID = nil
    }

    mutating func meetingEnded(_ meeting: DetectedMeeting) -> Bool {
        let shouldStop = recordingMeetingBundleID == meeting.bundleID
        if detectedMeetingBundleID == meeting.bundleID {
            detectedMeetingBundleID = nil
        }
        if shouldStop {
            recordingMeetingBundleID = nil
        }
        return shouldStop
    }
}
