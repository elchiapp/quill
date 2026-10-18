import CoreServices
import Foundation

struct LibraryChanges: Sendable {
    var content = false
    var semantics = false
    var pendingTranscription = false

    var isEmpty: Bool { !content && !semantics && !pendingTranscription }

    mutating func merge(_ other: Self) {
        content = content || other.content
        semantics = semantics || other.semantics
        pendingTranscription = pendingTranscription || other.pendingTranscription
    }

    static func classify(
        path: String, recordingRoot: URL, knowledgeRoot: URL, fileArrived: Bool = false
    ) -> Self {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let recordings = recordingRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let knowledge = knowledgeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let semanticRoot = recordingRoot.deletingLastPathComponent()
            .appendingPathComponent("Semantics").resolvingSymlinksInPath().standardizedFileURL.path
        if url.path == semanticRoot || url.path.hasPrefix(semanticRoot + "/") {
            return Self(semantics: true)
        }
        guard url.path == recordings || url.path.hasPrefix(recordings + "/")
                || url.path == knowledge || url.path.hasPrefix(knowledge + "/")
        else { return Self() }

        // Folder changes cover new, deleted, renamed and newly hydrated items.
        let base = url.path.hasPrefix(recordings + "/") ? recordings : knowledge
        let relative = url.path == recordings || url.path == knowledge
            ? "" : String(url.path.dropFirst(base.count + 1))
        if !relative.contains("/") {
            return Self(content: true, pendingTranscription: true)
        }
        var name = url.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(7))
        }
        let pendingFiles: Set<String> = [
            "meta.json", "transcript.json", ".transcription-pending", ".recording-active",
        ]
        let contentFiles: Set<String> = pendingFiles.union([
            "item.json", "title.txt", "notes.md", "content.md", "speakers.json",
            "terminology.json", "presentation.json", "summary.json",
        ])
        if fileArrived {
            let audioExtensions: Set<String> = ["caf", "m4a", "wav", "mp3", "aac", "flac", "aiff", "mp4"]
            let isAudio = audioExtensions.contains((name as NSString).pathExtension.lowercased())
            if isAudio || name.hasPrefix("asset.") {
                return Self(
                    content: true,
                    pendingTranscription: isAudio && url.path.hasPrefix(recordings + "/")
                )
            }
        }
        // Audio, transcription logs and temporary writes cannot change the UI.
        return Self(
            content: contentFiles.contains(name),
            pendingTranscription: url.path.hasPrefix(recordings + "/")
                && pendingFiles.contains(name)
        )
    }
}

/// FSEvents sleeps in the OS until the library changes. There is no idle timer.
@MainActor
final class LibraryChangeMonitor {
    private var stream: FSEventStreamRef?
    private var deliveryTask: Task<Void, Never>?
    private var pending = LibraryChanges()
    private var knownAssetIdentities: [String: String] = [:]
    private let recordingRoot: URL
    private let knowledgeRoot: URL
    private let onChange: @MainActor (LibraryChanges) -> Void

    init(
        recordingRoot: URL,
        knowledgeRoot: URL,
        onChange: @escaping @MainActor (LibraryChanges) -> Void
    ) {
        self.recordingRoot = recordingRoot
        self.knowledgeRoot = knowledgeRoot
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        // FSEvents can retain ItemCreated in a later modification event. Snapshot
        // existing asset identities once, so appending audio is not an arrival.
        for root in [recordingRoot, knowledgeRoot] {
            let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            while let url = files?.nextObject() as? URL {
                guard Self.isAsset(url), let identity = Self.assetIdentity(url) else { continue }
                knownAssetIdentities[url.resolvingSymlinksInPath().standardizedFileURL.path] = identity
            }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = Array(Set([
            recordingRoot.deletingLastPathComponent().path,
            knowledgeRoot.deletingLastPathComponent().path,
        ])) as CFArray
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let monitor = Unmanaged<LibraryChangeMonitor>
                    .fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
                MainActor.assumeIsolated {
                    for index in 0..<count {
                        monitor.receive(path: paths[index], flags: flags[index])
                    }
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
            )
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
    }

    func stop() {
        deliveryTask?.cancel()
        deliveryTask = nil
        pending = LibraryChanges()
        knownAssetIdentities.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func receive(path: String, flags: FSEventStreamEventFlags) {
        let dropped = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        ) != 0
        var arrived = flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemRemoved
        ) != 0
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        if Self.isAsset(url) {
            let identity = Self.assetIdentity(url)
            if let identity, knownAssetIdentities[url.path] == identity { arrived = false }
            knownAssetIdentities[url.path] = identity
        }
        pending.merge(dropped
            ? LibraryChanges(content: true, semantics: true, pendingTranscription: true)
            : LibraryChanges.classify(
                path: path, recordingRoot: recordingRoot, knowledgeRoot: knowledgeRoot,
                fileArrived: arrived
            ))
        guard !pending.isEmpty else { return }
        // One bounded delivery per burst; continuous audio writes cannot postpone it.
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            guard let self else { return }
            let changes = self.pending
            self.pending = LibraryChanges()
            self.deliveryTask = nil
            self.onChange(changes)
        }
    }

    private static func isAsset(_ url: URL) -> Bool {
        ["caf", "m4a", "wav", "mp3", "aac", "flac", "aiff", "mp4"]
            .contains(url.pathExtension.lowercased()) || url.lastPathComponent.hasPrefix("asset.")
    }

    private static func assetIdentity(_ url: URL) -> String? {
        // Do not count a cloud placeholder as an already hydrated asset.
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           values.ubiquitousItemDownloadingStatus == .notDownloaded { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
}
