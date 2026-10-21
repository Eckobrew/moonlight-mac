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

        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
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
            if sessionController.isStreaming || appState.isStreaming {
                StreamingSessionView(
                    sessionController: sessionController,
                    onDisconnect: {
                        appState.stopActiveStream()
                    }
                )
            } else if appState.isShortcutLaunch {
                StreamNegotiationView(appState: appState)
            } else {
                NavigationStack {
                    HostGridView(appState: appState)
                        .navigationTitle("Moonlight")
                }
            }
        }
        .frame(
            minWidth: appState.isShortcutLaunch && !sessionController.isStreaming && !appState.isStreaming ? 460 : 800,
            minHeight: appState.isShortcutLaunch && !sessionController.isStreaming && !appState.isStreaming ? 380 : 550
        )
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            for window in NSApplication.shared.windows {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
        .alert("Stream Error", isPresented: Binding(
            get: { sessionController.sessionError != nil },
            set: { if !$0 { sessionController.clearError() } }
        )) {
            Button("OK", role: .cancel) {
                sessionController.clearError()
                if sessionController.isShortcutMode {
                    exit(0)
                }
            }
        } message: {
            if let error = sessionController.sessionError {
                Text(error)
            }
        }
    }
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
