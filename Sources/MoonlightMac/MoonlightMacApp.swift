import SwiftUI

@main
struct MoonlightMacApp: App {
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
                } else {
                    NavigationStack {
                        HostGridView(appState: appState)
                            .navigationTitle("Moonlight")
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 550)
            .task {
                handleCommandLineArguments()
            }
            .alert("Stream Error", isPresented: Binding(
                get: { sessionController.sessionError != nil },
                set: { if !$0 { sessionController.clearError() } }
            )) {
                Button("OK", role: .cancel) {
                    sessionController.clearError()
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

        if let iconIdx = args.firstIndex(of: "--icon"), iconIdx + 1 < args.count {
            let iconPath = args[iconIdx + 1]
            if FileManager.default.fileExists(atPath: iconPath), let img = NSImage(contentsOfFile: iconPath) {
                NSApp.applicationIconImage = img
            }
        }

        Task {
            await appState.handleCLIStream(hostQuery: hostQuery, appQuery: appQuery)
        }
    }
}
