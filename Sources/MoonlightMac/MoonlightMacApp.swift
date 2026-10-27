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
        if controller.isStreaming, controller.shouldQuitHostAppOnStop,
           let host = controller.activeHost {
            let expectedAppID = controller.hostAppIDForShutdown
            Task {
                await HostAppShutdown.quit(host: host, expectedAppID: expectedAppID)
                sender.reply(toApplicationShouldTerminate: true)
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
            if appState.isShortcutLaunch {
                StreamNegotiationView(appState: appState)
            } else {
                NavigationStack {
                    HostGridView(appState: appState)
                        .navigationTitle(AppLocalization.text("Moonlight"))
                }
            }
        }
        .frame(
            minWidth: appState.isShortcutLaunch ? 460 : 800,
            minHeight: appState.isShortcutLaunch ? 380 : 550
        )
        .background(BrowserWindowReader())
        .onAppear { ControllerUINavigation.shared.start(state: appState) }
        .onChange(of: appState.isStreaming) { _, _ in ControllerUINavigation.shared.refresh() }
        .alert(AppLocalization.text("Stream Error"), isPresented: Binding(
            get: { sessionController.sessionError != nil },
            set: { if !$0 { sessionController.clearError() } }
        )) {
            Button(AppLocalization.text("OK"), role: .cancel) {
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

/// Track the browser independently of the ephemeral stream and its sheets.
private struct BrowserWindowReader: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowManager.shared.setBrowserWindow(window) }
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
        Window("Moonlight", id: "host-browser") {
            RootContentView(appState: appState)
                .task {
                    handleCommandLineArguments()
                }
        }
        // A separate identity also retires the old shared browser/stream state.
        .defaultSize(width: appState.isShortcutLaunch ? 460 : 900,
                     height: appState.isShortcutLaunch ? 380 : 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(AppLocalization.text("Add Host...")) {
                    appState.isShowingAddHost = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(AppLocalization.text("Refresh Hosts")) {
                    Task {
                        await appState.refreshHosts()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .appSettings) {
                Button(AppLocalization.text("Preferences...")) {
                    if appState.isStreaming {
                        StreamSessionController.shared.openSessionControls()
                    } else {
                        appState.isShowingSettings = true
                    }
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

        appState.beginCLIStream(hostQuery: hostQuery, appQuery: appQuery)
    }
}
