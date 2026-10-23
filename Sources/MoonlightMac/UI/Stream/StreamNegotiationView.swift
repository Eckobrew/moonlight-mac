import SwiftUI
import AppKit

public struct StreamNegotiationView: View {
    @Bindable public var appState: AppState
    @ObservedObject private var sessionController = StreamSessionController.shared

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // App / Game Icon
                if let icon = appState.cliIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 130, height: 130)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)

                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.white)
                    }
                }

                // Title & Host Subtitle
                VStack(spacing: 6) {
                    Text(appState.cliGameTitle.isEmpty ? "Starting Game" : appState.cliGameTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)

                    if !appState.cliHostName.isEmpty {
                        Text("Streaming from \(appState.cliHostName)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }

                // Progress Indicator & Status
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .controlSize(.regular)

                    Text(currentStatusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 8)

                Spacer()

                // Cancel Button
                Button("Cancel") {
                    appState.cancelShortcutLaunch()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 440, minHeight: 380)
        .alert("Unable to Start Stream", isPresented: Binding(
            get: { appState.cliStreamError != nil },
            set: { if !$0 { appState.cliStreamError = nil } }
        )) {
            Button("Quit", role: .cancel) {
                exit(0)
            }
        } message: {
            if let error = appState.cliStreamError {
                Text(error)
            }
        }
    }

    private var currentStatusText: String {
        if !sessionController.currentStageName.isEmpty &&
           sessionController.currentStageName != "Starting Limelight..." &&
           sessionController.currentStageName != "Connected" {
            return sessionController.currentStageName
        }
        return appState.cliStreamStatus
    }
}
