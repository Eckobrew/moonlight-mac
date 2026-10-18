import SwiftUI

public struct StreamingSessionView: View {
    @ObservedObject public var sessionController: StreamSessionController
    public let onDisconnect: () -> Void

    @State private var showHud: Bool = true
    @State private var showControls: Bool = false
    @State private var controlsTimer: Timer?

    public init(sessionController: StreamSessionController, onDisconnect: @escaping () -> Void) {
        self.sessionController = sessionController
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Metal Stream Render View
            MTKViewRepresentable(preferredFps: sessionController.metrics.targetFps)
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

            // Top control bar (appears on hover or when paused)
            VStack {
                if showControls {
                    HStack {
                        Button {
                            showHud.toggle()
                        } label: {
                            Label(showHud ? "Hide HUD" : "Show HUD", systemImage: showHud ? "chart.xyaxis.line" : "chart.line.uptrend.xyaxis")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        Spacer()

                        Text("Press ⌘ + ⌃ + Q to release cursor / exit")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: Capsule())

                        Spacer()

                        Button(role: .destructive) {
                            onDisconnect()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()
            }

            // Floating Performance HUD
            if showHud && sessionController.currentStageName == "Connected" {
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = hovering
            }
        }
        .background {
            Button("") {
                showHud.toggle()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .opacity(0)
        }
    }
}
