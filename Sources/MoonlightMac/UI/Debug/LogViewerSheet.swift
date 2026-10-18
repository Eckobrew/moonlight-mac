import SwiftUI
import AppKit

public struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [LogEntry] = []
    @State private var filterText: String = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var autoScroll: Bool = true
    @State private var timer: Timer?

    public init() {}

    private var filteredLogs: [LogEntry] {
        logs.filter { entry in
            if let level = selectedLevel, entry.level != level {
                return false
            }
            if !filterText.isEmpty {
                let lower = filterText.lowercased()
                return entry.message.lowercased().contains(lower) ||
                       entry.category.lowercased().contains(lower)
            }
            return true
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Label("Moonlight Diagnostics & Logs", systemImage: "terminal.fill")
                    .font(.headline)

                Spacer()

                Button(action: revealLogInFinder) {
                    Label("Reveal Log File", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .help("Open moonlight.log in Finder")

                Button(action: copyAllLogs) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(action: clearLogs) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Filter bar
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter logs...", text: $filterText)
                        .textFieldStyle(.plain)
                    if !filterText.isEmpty {
                        Button(action: { filterText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // Log entries list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Text("[\(entry.category)]")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.blue)
                                    .frame(width: 90, alignment: .leading)

                                Text("[\(entry.level.rawValue)]")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(levelColor(entry.level))
                                    .frame(width: 55, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: filteredLogs.count) { _, _ in
                    if autoScroll, let last = filteredLogs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .onAppear {
            refreshLogs()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    refreshLogs()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refreshLogs() {
        let entries = AppLogger.shared.getRecentEntries()
        if entries != logs {
            self.logs = entries
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func copyAllLogs() {
        let text = logs.map(\.logLine).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clearLogs() {
        AppLogger.shared.clearLogs()
        logs.removeAll()
    }

    private func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.logFileURL])
    }
}
