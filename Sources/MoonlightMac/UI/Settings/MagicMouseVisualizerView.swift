//
//  MagicMouseVisualizerView.swift
//  MoonlightMac
//

import SwiftUI
import AppKit
import MoonlightCommonC

public struct MagicMouseVisualizerView: View {
    @ObservedObject public var deviceManager = MultitouchDeviceManager.shared
    public var leftThreshold: Double
    public var rightThreshold: Double
    public var palmThreshold: Double

    @State private var snapshot = ChordEngineSnapshot()
    @State private var touches: [SurfaceTouch] = []
    @State private var localClickMonitor: Any?

    private let refreshTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    public init(leftThreshold: Double, rightThreshold: Double, palmThreshold: Double) {
        self.leftThreshold = leftThreshold
        self.rightThreshold = rightThreshold
        self.palmThreshold = palmThreshold
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left: Mouse Surface Canvas
            mouseSurfaceCard

            // Right: Real-time Status HUD
            VStack(spacing: 12) {
                connectionCard
                statusCard
                touchReadoutCard
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            MagicChordEngine.shared.leftThreshold = leftThreshold
            MagicChordEngine.shared.rightThreshold = rightThreshold
            MagicChordEngine.shared.palmThreshold = palmThreshold
            deviceManager.delegate = MagicChordEngine.shared
            deviceManager.start(requester: "VisualizerView")

            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp
            ]) { event in
                if MagicMouseIdentifier.shared.isMagicMouse(event: event) {
                    switch event.type {
                    case .leftMouseDown:
                        MagicChordEngine.shared.handleMouseDown(button: BUTTON_LEFT)
                    case .leftMouseUp:
                        MagicChordEngine.shared.handleMouseUp(button: BUTTON_LEFT)
                    case .rightMouseDown:
                        MagicChordEngine.shared.handleMouseDown(button: BUTTON_RIGHT)
                    case .rightMouseUp:
                        MagicChordEngine.shared.handleMouseUp(button: BUTTON_RIGHT)
                    default:
                        break
                    }
                    pullState()
                }
                return event
            }
            pullState()
        }
        .onDisappear {
            if let monitor = localClickMonitor {
                NSEvent.removeMonitor(monitor)
                localClickMonitor = nil
            }
            MagicChordEngine.shared.reset()
            deviceManager.stop(requester: "VisualizerView")
        }
        .onChange(of: leftThreshold) { _, newValue in
            MagicChordEngine.shared.leftThreshold = newValue
        }
        .onChange(of: rightThreshold) { _, newValue in
            MagicChordEngine.shared.rightThreshold = newValue
        }
        .onChange(of: palmThreshold) { _, newValue in
            MagicChordEngine.shared.palmThreshold = newValue
        }
        .onReceive(refreshTimer) { _ in
            pullState()
        }
    }

    private func pullState() {
        self.snapshot = MagicChordEngine.shared.getSnapshot()
        self.touches = deviceManager.getLatestTouches()
    }

    // MARK: - Connection Card
    private var connectionCard: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(deviceManager.isMagicMouseConnected ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Text(deviceManager.isMagicMouseConnected ? "Magic Mouse Connected" : "Waiting for Magic Mouse...")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Mouse Canvas Card
    private var mouseSurfaceCard: some View {
        VStack(spacing: 8) {
            ZStack {
                // Mouse Outer Silhouette
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(NSColor.controlBackgroundColor), Color(NSColor.windowBackgroundColor)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 44, style: .continuous)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)

                // Mouse Zones Division
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height

                    // Left Zone
                    Path { p in
                        p.addRect(CGRect(x: 0, y: 0, width: w * CGFloat(leftThreshold), height: h * CGFloat(1.0 - palmThreshold)))
                    }
                    .fill(Color.blue.opacity(snapshot.hasLeftTouch ? 0.24 : 0.08))

                    // Right Zone
                    Path { p in
                        let startX = w * CGFloat(rightThreshold)
                        p.addRect(CGRect(x: startX, y: 0, width: w - startX, height: h * CGFloat(1.0 - palmThreshold)))
                    }
                    .fill(Color.orange.opacity(snapshot.hasRightTouch ? 0.24 : 0.08))

                    // Deadzone Vertical Strip
                    Path { p in
                        let startX = w * CGFloat(leftThreshold)
                        let endX = w * CGFloat(rightThreshold)
                        p.addRect(CGRect(x: startX, y: 0, width: endX - startX, height: h * CGFloat(1.0 - palmThreshold)))
                    }
                    .fill(Color.gray.opacity(0.06))

                    // Palm Rejection Area (Bottom)
                    Path { p in
                        let topY = h * CGFloat(1.0 - palmThreshold)
                        p.addRect(CGRect(x: 0, y: topY, width: w, height: h - topY))
                    }
                    .fill(Color.red.opacity(0.06))

                    // Center Guide Line
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: 16))
                        p.addLine(to: CGPoint(x: w / 2, y: h * CGFloat(1.0 - palmThreshold)))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(Color.secondary.opacity(0.4))

                    // Zone Labels
                    Text("LEFT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.blue.opacity(0.75))
                        .position(x: max(16, w * CGFloat(leftThreshold) / 2), y: 26)

                    Text("RIGHT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.orange.opacity(0.75))
                        .position(x: min(w - 16, w * CGFloat(rightThreshold) + (w * CGFloat(1.0 - rightThreshold) / 2)), y: 26)

                    Text("PALM REJECTION")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color.secondary.opacity(0.55))
                        .position(x: w / 2, y: h - 14)

                    // Real-Time Active Touches
                    ForEach(touches) { touch in
                        if touch.isTouching {
                            let posX = w * CGFloat(touch.x)
                            let posY = h * CGFloat(1.0 - touch.y)

                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.35))
                                    .frame(width: 32, height: 32)
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 12, height: 12)
                                    .shadow(radius: 2)
                            }
                            .position(x: posX, y: posY)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
            }
            .frame(width: 190, height: 290)
        }
    }

    // MARK: - Status Card
    private var statusCard: some View {
        VStack(spacing: 10) {
            // Both Buttons Down Banner
            if snapshot.isBothButtonsActive {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.yellow)
                    Text("BOTH BUTTONS DOWN ACTIVE")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                )
            }

            // Left vs Right Status
            HStack(spacing: 10) {
                buttonStateView(
                    title: "Left Button",
                    isActive: snapshot.isLeftButtonActive,
                    isEmulated: snapshot.isLeftEmulated,
                    hasTouch: snapshot.hasLeftTouch,
                    tintColor: .blue
                )

                buttonStateView(
                    title: "Right Button",
                    isActive: snapshot.isRightButtonActive,
                    isEmulated: snapshot.isRightEmulated,
                    hasTouch: snapshot.hasRightTouch,
                    tintColor: .orange
                )
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func buttonStateView(title: String, isActive: Bool, isEmulated: Bool, hasTouch: Bool, tintColor: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)

            Text(isActive ? "DOWN" : "UP")
                .font(.system(size: 14, weight: .black))
                .foregroundColor(isActive ? tintColor : .secondary)

            if isActive {
                Text(isEmulated ? "EMULATED" : "PHYSICAL")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isEmulated ? .purple : .green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((isEmulated ? Color.purple : Color.green).opacity(0.15))
                    .cornerRadius(4)
            } else if hasTouch {
                Text("TOUCHED")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            } else {
                Text("RELEASED")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? tintColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - Touch Readout Card
    private var touchReadoutCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Fingers: \(touches.filter { $0.isTouching }.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if touches.filter({ $0.isTouching }).isEmpty {
                Text("Place your fingers on the Magic Mouse to test.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                ForEach(touches.filter { $0.isTouching }) { t in
                    let zoneName: String = {
                        switch t.zone(leftThreshold: leftThreshold, rightThreshold: rightThreshold, palmThreshold: palmThreshold) {
                        case .left: return "Left Zone"
                        case .right: return "Right Zone"
                        case .deadzone: return "Deadzone"
                        case .palmRejection: return "Palm Rejection"
                        }
                    }()
                    HStack {
                        Text("Finger #\(t.id):")
                            .font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text("X: \(String(format: "%.2f", t.x))  Y: \(String(format: "%.2f", t.y)) (\(zoneName))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}
