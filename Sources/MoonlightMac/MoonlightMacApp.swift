import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments
        if let iconIdx = args.firstIndex(of: "--icon"), iconIdx + 1 < args.count {
            let iconPath = args[iconIdx + 1]
            if FileManager.default.fileExists(atPath: iconPath), let img = NSImage(contentsOfFile: iconPath) {
                NSApplication.shared.applicationIconImage = img
            }
        }


    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showCurrentWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return StreamSessionController.shared.isShortcutMode
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = StreamSessionController.shared
        if (controller.isShortcutMode || controller.activeSettings?.quitAppOnStop == true),
           let host = controller.activeHost {
            for window in sender.windows {
                window.orderOut(nil)
                window.setIsVisible(false)
            }
            Task.detached(priority: .userInitiated) {
                AppLogger.shared.info("Application terminating: requesting host to quit app...", category: "SESSION")
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try? await SunshineHTTPClient.shared.quitApp(host: host)
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                    }
                    _ = await group.next()
                }
                exit(0)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

struct RootContentView: View {
    @Bindable var appState: AppState
    @ObservedObject var sessionController = StreamSessionController.shared

    var body: some View {
        Group {
            if sessionController.isStreaming {
                StreamingSessionView(
                    sessionController: sessionController,
                    onDisconnect: {
                        appState.stopActiveStream()
                    }
                )
            } else if appState.isShortcutLaunch && !appState.hasStartedStreaming {
                StreamNegotiationView(appState: appState)
            } else if appState.isShortcutLaunch {
                Color.black.ignoresSafeArea()
            } else {
                NavigationStack {
                    HostGridView(appState: appState)
                        .navigationTitle("Moonlight")
                }
            }
        }
        .frame(
            minWidth: appState.isShortcutLaunch && !appState.hasStartedStreaming ? 460 : 800,
            minHeight: appState.isShortcutLaunch && !appState.hasStartedStreaming ? 380 : 550
        )
        .background(ContentWindowReader())
        .alert("Stream Error", isPresented: Binding(
            get: { sessionController.sessionError != nil },
            set: { if !$0 { sessionController.clearError() } }
        )) {
            Button("OK", role: .cancel) {
                if sessionController.isShortcutMode || appState.isShortcutLaunch {
                    // Return to the shortcut launch UI after dismissing the error.
                    appState.failShortcutLaunch()
                } else {
                    appState.stopActiveStream()
                }
                sessionController.clearError()
            }
        } message: {
            if let error = sessionController.sessionError {
                Text(error)
            }
        }
    }
}

/// Track the window hosting the UI instead of guessing from transient key-window
/// state during sheet dismissal, view replacement, or fullscreen restoration.
private struct ContentWindowReader: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowManager.shared.setContentWindow(window) }
        }
    }

    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {}
}

@main
struct MoonlightMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootContentView(appState: appState)
                .task {
                    handleCommandLineArguments()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Host...") {
                    appState.isShowingAddHost = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Refresh Hosts") {
                    Task {
                        await appState.refreshHosts()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .appSettings) {
                Button("Preferences...") {
                    appState.isShowingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func handleCommandLineArguments() {
        let args = CommandLine.arguments
        guard let streamIdx = args.firstIndex(of: "stream"), streamIdx + 2 < args.count else {
            return
        }

        let hostQuery = args[streamIdx + 1]
        let appQuery = args[streamIdx + 2]

        Task {
            await appState.handleCLIStream(hostQuery: hostQuery, appQuery: appQuery)
        }
    }
}
