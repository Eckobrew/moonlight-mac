import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ShortcutIconPickerSheet: View {
    public let host: Host
    public let app: StreamApp
    public let boxArtImage: NSImage?

    @Environment(\.dismiss) private var dismiss

    @StateObject private var searchService = GameArtworkSearchService.shared
    @State private var searchQuery: String = ""
    @State private var selectedCategory: ArtworkCategory = .all
    @State private var selectedCandidateId: String? = "host_box_art"
    @State private var selectedImage: NSImage?
    @State private var iconStyle: ShortcutIconStyle = .squircle
    @State private var fillMode: ShortcutFillMode = .aspectFill

    @State private var customLocalImage: NSImage?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false

    @AppStorage("steamgriddb_api_key") private var steamGridDBKey: String = ""
    @State private var showSGDBField = false

    public init(host: Host, app: StreamApp, boxArtImage: NSImage?) {
        self.host = host
        self.app = app
        self.boxArtImage = boxArtImage
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(Divider(), alignment: .bottom)

            // Main Content: Split into Search/Gallery and Preview Panel
            HStack(spacing: 0) {
                // Left Pane: Search bar, category filters, and artwork grid
                VStack(spacing: 12) {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    categoryFilterBar
                        .padding(.horizontal, 16)

                    Divider()

                    artworkGrid
                        .padding(.horizontal, 16)

                    sgdbDisclosure
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .frame(minWidth: 460)

                Divider()

                // Right Pane: Live Desktop icon preview & options
                VStack(spacing: 18) {
                    Text("Desktop Preview")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    desktopSimulationPreview

                    Divider()

                    // Style options
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Icon Format")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Picker("", selection: $iconStyle) {
                                ForEach(ShortcutIconStyle.allCases) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if iconStyle == .squircle {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Artwork Scaling")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Picker("", selection: $fillMode) {
                                    ForEach(ShortcutFillMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }

                    Spacer()

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)

                        Button {
                            createShortcut()
                        } label: {
                            if isCreating {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 80)
                            } else {
                                Label("Create Shortcut", systemImage: "arrow.up.forward.app")
                                    .frame(minWidth: 120)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedImage == nil && boxArtImage == nil && customLocalImage == nil)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 270)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
        }
        .frame(width: 770, height: 620)
        .onAppear {
            if selectedImage == nil {
                selectedImage = boxArtImage
            }
            searchQuery = app.title
            searchService.search(query: app.title, hostBoxArt: boxArtImage, hostAppName: app.title)
        }
        .alert("Shortcut Created", isPresented: $showSuccessAlert) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Shortcut for '\(app.title)' was created successfully on your Desktop.")
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Desktop Shortcut")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Choose or search online for high quality game icons for '\(app.title)'.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search online game artwork (e.g. \(app.title))...", text: $searchQuery)
                .textFieldStyle(.plain)
                .onSubmit {
                    searchService.search(query: searchQuery, hostBoxArt: boxArtImage, hostAppName: app.title)
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if searchService.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            Button("Search") {
                searchService.search(query: searchQuery, hostBoxArt: boxArtImage, hostAppName: app.title)
            }
            .buttonStyle(.bordered)
            .disabled(searchService.isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Category Filters
    private var categoryFilterBar: some View {
        HStack(spacing: 8) {
            ForEach(ArtworkCategory.allCases) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    Text(cat.rawValue)
                        .font(.caption)
                        .fontWeight(selectedCategory == cat ? .semibold : .regular)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            selectedCategory == cat ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                            in: Capsule()
                        )
                        .foregroundStyle(selectedCategory == cat ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Artwork Grid
    private var filteredCandidates: [GameArtworkCandidate] {
        if selectedCategory == .all {
            return searchService.candidates
        }
        return searchService.candidates.filter { $0.category == selectedCategory }
    }

    private var artworkGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 14)], spacing: 14) {
                // 1. Choose Local Image Card
                localFilePickerCard

                // 2. Custom local image if loaded
                if let custom = customLocalImage {
                    candidateCard(
                        id: "local_custom",
                        title: "Custom Image",
                        subtitle: "From your Mac",
                        source: "Local",
                        image: custom,
                        isSelected: selectedCandidateId == "local_custom"
                    ) {
                        selectedCandidateId = "local_custom"
                        selectedImage = custom
                    }
                }

                // 3. Online Candidates
                ForEach(filteredCandidates) { candidate in
                    CandidateCell(
                        candidate: candidate,
                        isSelected: selectedCandidateId == candidate.id,
                        onSelect: { img in
                            selectedCandidateId = candidate.id
                            selectedImage = img
                        }
                    )
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Local File Picker Card
    private var localFilePickerCard: some View {
        Button {
            pickLocalFile()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .aspectRatio(1.0, contentMode: .fit)

                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.accentColor)
                        Text("Browse File...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }

                Text("Custom Image")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func candidateCard(
        id: String,
        title: String,
        subtitle: String,
        source: String,
        image: NSImage,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.0, contentMode: .fit)
                        .background(Color.black.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                        )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor, Color.white)
                            .padding(6)
                    }

                    Text(source)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                VStack(spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - SteamGridDB Disclosure
    private var sgdbDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation {
                    showSGDBField.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSGDBField ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("SteamGridDB API Key (Optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showSGDBField {
                HStack(spacing: 8) {
                    SecureField("Paste SteamGridDB key...", text: $steamGridDBKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save & Search") {
                        searchService.search(query: searchQuery, hostBoxArt: boxArtImage, hostAppName: app.title)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("Get a free key at steamgriddb.com/profile/preferences/api to unlock community artwork.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Desktop Preview Simulation
    private var currentFormattedIcon: NSImage {
        let baseImage = selectedImage ?? boxArtImage ?? customLocalImage ?? NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) ?? NSImage()
        return GameShortcutManager.shared.formatIcon(
            from: baseImage,
            style: iconStyle,
            fillMode: fillMode,
            size: 256
        )
    }

    private var desktopSimulationPreview: some View {
        VStack(spacing: 8) {
            ZStack {
                // Subtle desktop wallpaper background preview
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.18), Color.purple.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 160)

                VStack(spacing: 6) {
                    Image(nsImage: currentFormattedIcon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 88, height: 88)

                    Text(app.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - Actions
    private func pickLocalFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Image for Shortcut"
        panel.message = "Choose an image file (.png, .jpg, .icns, .ico) from your Mac."
        panel.prompt = "Choose Image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        var types: [UTType] = [.png, .jpeg]
        if let icns = UTType(filenameExtension: "icns") { types.append(icns) }
        if let ico = UTType(filenameExtension: "ico") { types.append(ico) }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            customLocalImage = img
            selectedImage = img
            selectedCandidateId = "local_custom"
        }
    }

    private func createShortcut() {
        guard let finalImage = selectedImage ?? boxArtImage ?? customLocalImage else {
            errorMessage = "Please choose an image for the shortcut."
            return
        }

        isCreating = true
        errorMessage = nil

        do {
            try GameShortcutManager.shared.createShortcut(
                for: app,
                host: host,
                image: finalImage,
                style: iconStyle,
                fillMode: fillMode
            )
            isCreating = false
            showSuccessAlert = true
        } catch {
            isCreating = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Candidate Cell
private struct CandidateCell: View {
    let candidate: GameArtworkCandidate
    let isSelected: Bool
    let onSelect: (NSImage) -> Void

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if !loadFailed {
                Button {
                    if let image = image {
                        onSelect(image)
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .aspectRatio(1.0, contentMode: .fit)

                                if let image = image {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                } else if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Color.clear
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                            )

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.accentColor, Color.white)
                                    .padding(6)
                            }

                            Text(candidate.sourceDescription)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.65), in: Capsule())
                                .padding(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        VStack(spacing: 2) {
                            Text(candidate.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(candidate.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .task(id: candidate.id) {
                    if let staticImg = candidate.staticImage {
                        image = staticImg
                        return
                    }

                    if let url = candidate.previewUrl ?? candidate.fullUrl {
                        isLoading = true
                        if let fetched = await GameArtworkSearchService.shared.fetchImage(from: url) {
                            image = fetched
                        } else {
                            loadFailed = true
                        }
                        isLoading = false
                    }
                }
            }
        }
    }
}
