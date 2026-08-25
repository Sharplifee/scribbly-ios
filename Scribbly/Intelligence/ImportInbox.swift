import Foundation
import os

/// Watches a shared folder for audio dropped in from outside the app.
///
/// WHY THIS EXISTS: Apple's native Call Recording saves into the Notes app.
/// Notes is not file-accessible to a third-party sandboxed app — there is no
/// API to enumerate its Call Recordings folder. So the recording has to be
/// handed to us rather than taken.
///
/// Two supported hand-off paths, both one-time setup:
///   1. A Shortcuts automation triggered on "call ends" that exports the newest
///      Call Recording into this app group container.
///   2. A Share Sheet extension — share the recording from Notes into the app.
///
/// Twilio-recorded call legs land here too, downloaded by the webhook client.
public actor ImportInbox {

    public struct Item: Equatable {
        public let url: URL
        public let discoveredAt: Date
        public let source: String
    }

    private let log = Logger(subsystem: "com.sharp.ambientcapture", category: "inbox")
    private let directory: URL
    private var seen: Set<String> = []
    private var monitor: DispatchSourceFileSystemObject?
    private var handler: ((Item) -> Void)?

    /// App Group so the Shortcut and the share extension can write here.
    public init(appGroupID: String = "group.com.sharp.ambientcapture") {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var inboxURL: URL { directory }

    public func onItem(_ handler: @escaping (Item) -> Void) {
        self.handler = handler
    }

    /// Scan now. Call on launch and on foreground — the folder may have been
    /// written to while the app was suspended.
    public func scan() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aac"]

        for url in files where audioExtensions.contains(url.pathExtension.lowercased()) {
            let key = url.lastPathComponent
            guard !seen.contains(key) else { continue }

            // Skip files still being written.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > 2
            else { continue }

            seen.insert(key)
            let item = Item(url: url, discoveredAt: Date(), source: Self.inferSource(url))
            log.info("inbox item \(key, privacy: .public) source=\(item.source, privacy: .public)")
            handler?(item)
        }
    }

    public func startWatching() {
        guard monitor == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot open inbox for watching")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { await self?.scan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        monitor = source
    }

    public func markProcessed(_ item: Item, delete: Bool) {
        if delete { try? FileManager.default.removeItem(at: item.url) }
    }

    private static func inferSource(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.contains("twilio") || name.contains("leg") { return "call_twilio" }
        if name.contains("call") || name.contains("recording") { return "call_native" }
        return "imported"
    }
}
