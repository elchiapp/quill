import DropsiftShared
import Foundation

@MainActor
final class MobileLibraryLocator: ObservableObject {
    @Published private(set) var rootURL: URL
    @Published private(set) var isConnectedToSharedFolder = false
    @Published private(set) var status = "On this iPhone"
    @Published var errorMessage: String?

    private static let bookmarkKey = "dropsift.sharedLibrary.bookmark"
    private var scopedURL: URL?

    init() {
        rootURL = Self.localRoot
        restoreBookmark()
        try? SharedLibraryStore(root: rootURL).prepare()
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    func connect(to selectedURL: URL) {
        let root = selectedURL.lastPathComponent == "Recordings"
            ? selectedURL.deletingLastPathComponent()
            : selectedURL
        let accessed = root.startAccessingSecurityScopedResource()
        do {
            try SharedLibraryStore(root: root).prepare()
            try Self.mergeLibrary(from: rootURL, into: root)
            let data = try root.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            if accessed {
                scopedURL?.stopAccessingSecurityScopedResource()
                scopedURL = root
            }
            rootURL = root
            isConnectedToSharedFolder = true
            status = Self.storageLabel(for: root)
            errorMessage = nil
        } catch {
            if accessed { root.stopAccessingSecurityScopedResource() }
            errorMessage = "Couldn’t connect this folder: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        rootURL = Self.localRoot
        isConnectedToSharedFolder = false
        status = "On this iPhone"
        try? SharedLibraryStore(root: rootURL).prepare()
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            return
        }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            scopedURL = url
            rootURL = url
            isConnectedToSharedFolder = true
            status = Self.storageLabel(for: url)
            if stale {
                let refreshed = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            rootURL = Self.localRoot
            isConnectedToSharedFolder = false
            status = "On this iPhone"
            errorMessage = "Reconnect your iCloud library to continue syncing."
        }
    }

    private static var localRoot: URL {
        let base = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Dropsift Library", isDirectory: true)
    }

    private static func storageLabel(for url: URL) -> String {
        let path = url.path.lowercased()
        if path.contains("mobile documents")
            || path.contains("file provider")
            || path.contains("icloud") {
            return "Shared through iCloud Drive"
        }
        return "Shared folder"
    }

    private static func mergeLibrary(from source: URL, into destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let fileManager = FileManager.default
        for folder in ["Items", "Recordings"] {
            let sourceFolder = source.appendingPathComponent(folder, isDirectory: true)
            let destinationFolder = destination.appendingPathComponent(folder, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: sourceFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            try fileManager.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
            for entry in entries {
                let target = destinationFolder.appendingPathComponent(
                    entry.lastPathComponent,
                    isDirectory: true
                )
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try fileManager.copyItem(at: entry, to: target)
            }
        }
    }
}
