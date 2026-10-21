import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = StreamSessionController.shared
        if (controller.isShortcutMode || controller.activeSettings?.quitAppOnStop == true),
           let host = controller.activeHost {
            Task {
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
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

@main
struct MoonlightMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @ObservedObject private var sessionController = StreamSessionController.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if sessionController.isStreaming {
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
                minWidth: appState.isShortcutLaunch && !sessionController.isStreaming ? 460 : 800,
                minHeight: appState.isShortcutLaunch && !sessionController.isStreaming ? 380 : 550
            )
            .task {
                handleCommandLineArguments()
            }
            .alert("Stream Error", isPresented: Binding(
                get: { sessionController.sessionError != nil },
                set: { if !$0 { sessionController.clearError() } }
            )) {
                Button("OK", role: .cancel) {
                    sessionController.clearError()
                    if sessionController.isShortcutMode {
                        NSApp.terminate(nil)
                    }
                }
            } message: {
                if let error = sessionController.sessionError {
                    Text(error)
                }
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
