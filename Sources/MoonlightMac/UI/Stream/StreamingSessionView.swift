import SwiftUI

public struct StreamingSessionView: View {
    @ObservedObject public var sessionController: StreamSessionController
    public let onDisconnect: () -> Void

    public init(sessionController: StreamSessionController, onDisconnect: @escaping () -> Void) {
        self.sessionController = sessionController
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Native hardware direct-scanout stream view (AVSampleBufferDisplayLayer)
            SampleBufferViewRepresentable(
                onWindowAttached: { window in
                    let mode = sessionController.activeSettings?.windowMode ?? .fullscreenDesktop
                    WindowManager.shared.applyStartupWindowMode(mode, for: window)
                }
            )
            .ignoresSafeArea()

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

            // Floating Performance HUD (toggle with Ctrl + Option + Shift + S)
            if sessionController.showPerformanceOverlay && sessionController.currentStageName == "Connected" {
                VStack {
                    HStack {
                        Spacer()
                        PerformanceHUDView(metrics: sessionController.metrics)
                            .padding(16)
                    }
                    Spacer()
                }
            }
        }
    }
}
