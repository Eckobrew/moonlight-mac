import SwiftUI

public struct StreamingSessionView: View {
    @ObservedObject public var sessionController: StreamSessionController
    @ObservedObject private var clipboard = ClipboardSyncManager.shared
    @ObservedObject private var services = RuntimeServiceStatus.shared
    public let onDisconnect: () -> Void

    public init(sessionController: StreamSessionController, onDisconnect: @escaping () -> Void) {
        self.sessionController = sessionController
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Stream view: Metal (default with VSync/tearing control) or Native AVSampleBufferDisplayLayer
            if sessionController.activeSettings?.videoRenderer == .native {
                SampleBufferViewRepresentable(
                    onWindowAttached: { window in
                        window.acceptsMouseMovedEvents = true
                        InputCaptureCoordinator.shared.mouseMonitor.setStreamWindow(window)
                        let mode = sessionController.activeSettings?.windowMode ?? .fullscreenDesktop
                        WindowManager.shared.applyStartupWindowMode(mode, for: window)
                        FramePacer.shared.updateWindow(window)
                    }
                )
                .ignoresSafeArea()
            } else {
                MetalStreamViewRepresentable(
                    rendererMode: sessionController.activeSettings?.videoRenderer ?? .metal,
                    enableVsync: sessionController.activeSettings?.enableVsync ?? true,
                    onWindowAttached: { window in
                        window.acceptsMouseMovedEvents = true
                        InputCaptureCoordinator.shared.mouseMonitor.setStreamWindow(window)
                        let mode = sessionController.activeSettings?.windowMode ?? .fullscreenDesktop
                        WindowManager.shared.applyStartupWindowMode(mode, for: window)
                        FramePacer.shared.updateWindow(window)
                    }
                )
                .ignoresSafeArea()
            }

            // Connecting progress indicator
            if sessionController.currentStageName != "Connected" {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)

                    Text(sessionController.currentStageName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }

            if let message = sessionController.connectionWarning ?? services.renderer ?? services.audio ?? clipboard.statusMessage ?? services.discord {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
                .allowsHitTesting(false)
            }

            // Floating Performance HUD (toggle with Ctrl + Option + Shift + S)
            if sessionController.showPerformanceOverlay && sessionController.currentStageName == "Connected" {
                VStack {
                    HStack {
                        Spacer()
                        PerformanceHUDView(session: sessionController)
                            .padding(16)
                    }
                    Spacer()
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Session controls…") { sessionController.openSessionControls() }
                    .keyboardShortcut("c", modifiers: [.control, .option, .shift])
            }
        }
        .sheet(isPresented: $sessionController.showSessionControls, onDismiss: { sessionController.closeSessionControls() }) {
            SessionControlsView(session: sessionController)
        }
    }
}
