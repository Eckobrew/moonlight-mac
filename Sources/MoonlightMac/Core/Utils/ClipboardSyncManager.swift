import AppKit
import Foundation

@MainActor
public final class ClipboardSyncManager {
    public static let shared = ClipboardSyncManager()

    private var activeHost: Host?
    private var isSyncAvailable: Bool = true
    /// Separate failure counters: a host that rejects pushes (or lacks the clipboard endpoint for
    /// pulls) should only disable the direction that is actually failing.
    private var sendErrors: Int = 0
    private var pullErrors: Int = 0
    private var lastSyncedClipboard: String = ""
    private var lastChangeCount: Int = -1

    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    // Each direction tracks its own in-flight request. A single shared flag let an in-flight send
    // suppress the pull (and vice-versa), starving one direction on slow links.
    private var isSending: Bool = false
    private var isPulling: Bool = false

    /// Identifies the current session, so a request that completes after `stop()`/`start()` cannot
    /// clear state belonging to the next session.
    private var sessionGeneration: UInt64 = 0

    private var pollCounter: Int = 0

    private init() {}

    /// Starts clipboard synchronization for the given streaming host.
    public func start(host: Host) {
        stop()

        self.activeHost = host
        self.isSyncAvailable = true
        self.sendErrors = 0
        self.pullErrors = 0
        self.lastSyncedClipboard = ""
        self.lastChangeCount = NSPasteboard.general.changeCount

        AppLogger.shared.info("Starting bidirectional clipboard synchronization with \(host.name)", category: "CLIPBOARD")

        // 1. Initial sync from host
        syncClipboardFromHost()

        // 2. Observe app focus gain and loss
        let activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncClipboardToHost()
            }
        }
        observers.append(activeObserver)

        let resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncClipboardFromHost()
            }
        }
        observers.append(resignObserver)

        // 3. Periodic timer: checks local pasteboard change every 0.5s, pulls host clipboard every 3.0s
        self.pollCounter = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTimerTick()
            }
        }
    }

    private func onTimerTick() {
        guard isSyncAvailable else { return }

        // Check if local pasteboard changed
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != lastChangeCount {
            lastChangeCount = currentCount
            syncClipboardToHost()
        }

        // Every 3.0s (6 ticks of 0.5s), pull host clipboard
        pollCounter += 1
        if pollCounter >= 6 {
            pollCounter = 0
            if NSApp.isActive {
                syncClipboardFromHost()
            }
        }
    }

    /// Stops clipboard synchronization and frees observers and timers.
    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()

        activeHost = nil
        // Invalidate any in-flight request: its completion handler checks the generation before
        // touching state, so it can no longer resurrect a dead session (previously `isSyncing`
        // stayed true forever if the session ended mid-request, disabling sync permanently).
        sessionGeneration &+= 1
        isSending = false
        isPulling = false
    }

    /// Pushes local macOS pasteboard string to the remote host.
    public func syncClipboardToHost() {
        guard isSyncAvailable, let host = activeHost, !isSending else { return }

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }

        // Limit to 10 MB to prevent excessive memory or network bandwidth usage
        if text.utf8.count > 10 * 1024 * 1024 {
            return
        }

        // Avoid echo loops
        if text == lastSyncedClipboard {
            return
        }

        lastSyncedClipboard = text
        isSending = true
        let generation = sessionGeneration

        Task {
            do {
                try await SunshineHTTPClient.shared.sendClipboardContent(host: host, text: text)
                await MainActor.run {
                    guard generation == self.sessionGeneration else { return }
                    self.isSending = false
                    self.sendErrors = 0
                    AppLogger.shared.debug("Sent \(text.count) characters to host clipboard", category: "CLIPBOARD")
                }
            } catch {
                await MainActor.run {
                    guard generation == self.sessionGeneration else { return }
                    self.isSending = false
                    self.sendErrors += 1
                    if self.sendErrors >= 3 {
                        self.isSyncAvailable = false
                        AppLogger.shared.warning("Repeated failures sending clipboard to host; disabling clipboard sync for this session.", category: "CLIPBOARD")
                    }
                }
            }
        }
    }

    /// Pulls remote host clipboard string to the macOS pasteboard.
    public func syncClipboardFromHost() {
        guard isSyncAvailable, let host = activeHost, !isPulling else { return }

        isPulling = true
        let generation = sessionGeneration

        Task {
            do {
                let hostText = try await SunshineHTTPClient.shared.getClipboardContent(host: host)
                await MainActor.run {
                    guard self.sessionGeneration == generation else { return }
                    self.isPulling = false
                    self.pullErrors = 0

                    if !hostText.isEmpty && hostText != self.lastSyncedClipboard {
                        self.lastSyncedClipboard = hostText
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hostText, forType: .string)
                        self.lastChangeCount = NSPasteboard.general.changeCount
                        AppLogger.shared.debug("Received \(hostText.count) characters from host clipboard", category: "CLIPBOARD")
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.sessionGeneration == generation else { return }
                    self.isPulling = false
                    self.pullErrors += 1
                    if self.pullErrors >= 3 {
                        self.isSyncAvailable = false
                        AppLogger.shared.warning("Clipboard sync disabled: host does not support clipboard sync or returned repeated errors.", category: "CLIPBOARD")
                    }
                }
            }
        }
    }
}
