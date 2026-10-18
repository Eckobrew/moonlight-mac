import SwiftUI

public struct AppCardView: View {
    public let app: StreamApp
    public let isStreaming: Bool
    public let onLaunch: () -> Void

    public init(app: StreamApp, isStreaming: Bool = false, onLaunch: @escaping () -> Void) {
        self.app = app
        self.isStreaming = isStreaming
        self.onLaunch = onLaunch
    }

    public var body: some View {
        VStack(spacing: 10) {
            // Box art container
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)

                if let url = app.boxArtUrl {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            fallbackIcon
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    fallbackIcon
                }

                if isStreaming {
                    Color.black.opacity(0.4)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                        Text("Active")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                    }
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
    }

    private var fallbackIcon: some View {
        Image(systemName: "gamecontroller.fill")
            .font(.system(size: 36, weight: .light))
            .foregroundStyle(.secondary)
    }
}
