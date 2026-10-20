import SwiftUI
import AppKit

public struct AppCardView: View {
    public let host: Host
    public let app: StreamApp
    public let isStreaming: Bool
    public let onLaunch: () -> Void
    public let onStop: (() -> Void)?

    @State private var boxArtImage: NSImage?
    @State private var isLoading = false
    @State private var showingShortcutSheet = false

    public init(
        host: Host,
        app: StreamApp,
        isStreaming: Bool = false,
        onLaunch: @escaping () -> Void,
        onStop: (() -> Void)? = nil
    ) {
        self.host = host
        self.app = app
        self.isStreaming = isStreaming
        self.onLaunch = onLaunch
        self.onStop = onStop
    }

    public var body: some View {
        VStack(spacing: 10) {
            // Box art container
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)

                if let image = boxArtImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    fallbackIcon
                }

                if isStreaming {
                    Color.black.opacity(0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("RUNNING")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())

                        Spacer()

                        // Action buttons: Resume stream or Stop app
                        HStack(spacing: 14) {
                            Button {
                                onLaunch()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(Color.blue, in: Circle())
                                    .shadow(radius: 4)
                            }
                            .buttonStyle(.plain)
                            .help("Resume stream")

                            if let onStop = onStop {
                                Button {
                                    onStop()
                                } label: {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(Color.red, in: Circle())
                                        .shadow(radius: 4)
                                }
                                .buttonStyle(.plain)
                                .help("Stop running application")
                            }
                        }

                        Spacer()
                    }
                    .padding(10)
                }
            }
            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)

            Text(app.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onLaunch()
        }
        .contextMenu {
            Button {
                onLaunch()
            } label: {
                Label(isStreaming ? "Resume Game" : "Launch Game", systemImage: isStreaming ? "play.fill" : "play")
            }

            if isStreaming, let onStop = onStop {
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Label("Stop Game", systemImage: "stop.fill")
                }
            }

            Divider()

            Button {
                showingShortcutSheet = true
            } label: {
                Label("Create Desktop Shortcut...", systemImage: "arrow.up.forward.app")
            }
        }
        .sheet(isPresented: $showingShortcutSheet) {
            ShortcutIconPickerSheet(host: host, app: app, boxArtImage: boxArtImage)
        }
        .task(id: app.id) {
            isLoading = true
            boxArtImage = await BoxArtManager.shared.getBoxArt(host: host, app: app)
            isLoading = false
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "gamecontroller.fill")
            .font(.system(size: 36, weight: .light))
            .foregroundStyle(.secondary)
    }
}
