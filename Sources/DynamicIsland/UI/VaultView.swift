import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Staging vault over the live mirrored folder tree.
///
/// Split into two independently-observing sections on purpose. Previously one
/// view read both services, so a filesystem event invalidated the staged rows —
/// and with them every thumbnail. Now an FSEvent redraws the folder list only.
struct VaultBody: View {
    var stagedHeight: CGFloat = IslandGeometry.stagedListHeight

    var body: some View {
        VStack(spacing: 0) {
            StagedSection(height: stagedHeight)
            Divider().overlay(Theme.hairline)
            MirrorSection()
        }
    }
}

/// Builds the payload for dragging an item *out* of the island.
///
/// `NSItemProvider(contentsOf:)` registers the file's real UTType and vends its
/// bytes, which is what makes the drop land as an attachment in Mail or Messages
/// and as a copied file in Finder — rather than as a path string.
enum DragPayload {
    static func provider(for item: StagedItem, url: URL?) -> NSItemProvider {
        Log.debug("drag-out staged \(item.kind.rawValue) '\(item.title)' → \(url?.lastPathComponent ?? "inline text")")
        if item.kind == .text, let text = item.text {
            return NSItemProvider(object: text as NSString)
        }
        if let url, let provider = NSItemProvider(contentsOf: url) {
            provider.suggestedName = url.lastPathComponent
            return provider
        }
        return NSItemProvider()
    }

    static func provider(for url: URL) -> NSItemProvider {
        Log.debug("drag-out mirrored \(url.lastPathComponent)")
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

// MARK: - Staged items

struct StagedSection: View {
    var height: CGFloat

    @EnvironmentObject private var vault: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: IslandGeometry.sectionSpacing) {
            HStack(spacing: 6) {
                Text("STAGED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .kerning(0.6)

                Text("\(vault.items.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.secondary)

                Spacer(minLength: 0)

                if !vault.items.isEmpty {
                    Button("Clear") { vault.clearAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: IslandGeometry.sectionLabelHeight)

            if vault.items.isEmpty {
                empty
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(vault.items) { item in
                            StagedRow(item: item)
                        }
                    }
                }
                .frame(height: height)
            }
        }
        .padding(.bottom, IslandGeometry.sectionBottomPadding)
    }

    private var empty: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            Text("Drag text, images, or files here")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

struct StagedRow: View {
    let item: StagedItem

    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var model: IslandModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if vault.lastCopiedID == item.id {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .transition(.scale.combined(with: .opacity))
            } else if hovering {
                HStack(spacing: 1) {
                    IslandIconButton(systemName: "doc.on.doc", size: 10, diameter: 22,
                                     tint: Theme.secondary) {
                        vault.copyToClipboard(item)
                    }
                    IslandIconButton(systemName: "tray.and.arrow.down", size: 10, diameter: 22,
                                     tint: Theme.secondary) {
                        model.file(item, into: model.selectedFolder ?? model.mirror.rootURL)
                    }
                    IslandIconButton(systemName: "xmark", size: 9, diameter: 22,
                                     tint: Theme.tertiary) {
                        vault.remove(item)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Theme.fill : Color.white.opacity(0.035))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        // Drag *out*: stage a screenshot here, then drag it straight into a
        // message, a mail draft, or a Finder window.
        .onDrag {
            DragPayload.provider(for: item, url: vault.url(for: item))
        } preview: {
            DragOutPreview(title: item.title, url: item.kind == .image ? vault.url(for: item) : nil,
                           symbol: item.kind == .text ? "text.alignleft" : "doc")
        }
    }

    private var subtitle: String {
        var parts: [String] = [item.kind.rawValue.capitalized]
        if item.isFiled { parts.append("filed") }
        parts.append(item.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    /// Decodes off-thread at draw size and caches — never synchronous I/O in `body`.
    private var thumbnail: some View {
        CachedThumbnail(
            url: item.kind == .image ? vault.url(for: item) : nil,
            side: 28,
            cornerRadius: 7
        ) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.fill)
                .overlay(
                    Image(systemName: item.kind == .text ? "text.alignleft" : "doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                )
        }
    }
}

// MARK: - Mirrored tree

struct MirrorSection: View {
    @EnvironmentObject private var mirror: FolderMirror
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: IslandGeometry.sectionSpacing) {
            HStack(spacing: 6) {
                Circle()
                    .fill(mirror.isWatching ? Theme.accent : Theme.tertiary)
                    .frame(width: 5, height: 5)

                Text(mirror.rootURL.lastPathComponent.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .kerning(0.6)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let event = mirror.lastEvent {
                    Text(event)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }

                IslandIconButton(systemName: "folder.badge.plus", size: 11, diameter: 22) {
                    model.isNamingFolder = true
                }
            }
            .frame(height: IslandGeometry.mirrorHeaderHeight)

            // One fixed slot for both, so starting to name a folder doesn't
            // change the island's height mid-interaction.
            Group {
                if model.isNamingFolder {
                    newFolderField
                } else {
                    destinationCrumb
                }
            }
            .frame(height: IslandGeometry.crumbSlotHeight)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if let root = mirror.root, !root.children.isEmpty {
                        ForEach(root.children) { node in
                            FolderRow(node: node, depth: 0)
                        }
                    } else {
                        Text("No folders yet — create one to start mirroring.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: IslandGeometry.folderListHeight)
        }
        .padding(.top, IslandGeometry.sectionBottomPadding)
    }

    private var newFolderField: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)

            TextField("Folder name", text: $model.newFolderName)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.primary)
                .onSubmit { model.commitNewFolder() }

            Button("Create") { model.commitNewFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill)
        )
    }

    private var destinationCrumb: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.tertiary)
            Text(destinationLabel)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.selectedFolder != nil {
                Button("Root") { model.selectedFolder = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var destinationLabel: String {
        let root = mirror.rootURL
        guard let selected = model.selectedFolder else { return root.lastPathComponent }
        return selected.path.replacingOccurrences(of: root.path, with: root.lastPathComponent)
    }
}

/// One node of the mirrored tree. Doubles as a drop target that writes straight
/// through to the corresponding directory on disk.
struct FolderRow: View {
    let node: MirrorNode
    let depth: Int

    @EnvironmentObject private var model: IslandModel
    @EnvironmentObject private var mirror: FolderMirror
    @State private var expanded = false
    @State private var hovering = false
    @State private var dropTargeted = false

    private var isSelected: Bool { model.selectedFolder == node.url }
    private var subfolders: [MirrorNode] { node.children.filter(\.isDirectory) }

    var body: some View {
        VStack(spacing: 2) {
            row
            if expanded {
                ForEach(subfolders) { child in
                    FolderRow(node: child, depth: depth + 1)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 7) {
            if node.isDirectory && !subfolders.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(node.isDirectory ? Theme.accent.opacity(0.85) : Theme.tertiary)

            Text(node.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if node.isDirectory && node.childCount > 0 {
                Text("\(node.childCount)")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 4)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(dropTargeted ? Theme.accent : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard node.isDirectory else { return }
            model.selectedFolder = isSelected ? nil : node.url
        }
        .onDrop(
            of: [.fileURL, .image, .png, .tiff, .plainText, .utf8PlainText, .text],
            isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = $0 })
        ) { providers in
            guard node.isDirectory else { return false }
            return model.handleDrop(providers: providers, into: node.url)
        }
        .contextMenu {
            Button("Reveal in Finder") { mirror.revealInFinder(node.url) }
            if node.isDirectory {
                Button("Set as Destination") { model.selectedFolder = node.url }
            }
            Divider()
            Button("Move to Trash") { try? mirror.trash(node.url) }
        }
        // Mirrored entries drag out too — the island behaves like a real folder
        // in both directions.
        .onDrag {
            DragPayload.provider(for: node.url)
        } preview: {
            DragOutPreview(
                title: node.name,
                url: nil,
                symbol: node.isDirectory ? "folder.fill" : "doc.fill"
            )
        }
    }

    private var background: Color {
        if dropTargeted { return Theme.accent.opacity(0.16) }
        if isSelected { return Theme.fillStrong }
        if hovering { return Theme.fill }
        return .clear
    }
}

/// Card that follows the cursor while an item is dragged out of the island.
struct DragOutPreview: View {
    let title: String
    let url: URL?
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            if let url {
                CachedThumbnail(url: url, side: 26, cornerRadius: 6) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill)
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill)
                    )
            }

            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 240)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.shell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }
}

/// Opens a folder picker for the mirror root.
struct MirrorRootButton: View {
    @EnvironmentObject private var model: IslandModel

    var body: some View {
        IslandIconButton(systemName: "folder.badge.gearshape", size: 11, diameter: 22,
                         tint: Theme.tertiary) {
            choose()
        }
    }

    /// The app is an `.accessory`, so it must activate before an NSOpenPanel can
    /// take keyboard focus — otherwise the panel appears behind and looks stuck.
    private func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Mirror Here"
        panel.message = "Choose the folder the Dynamic Island should mirror."
        panel.directoryURL = model.mirror.rootURL

        if panel.runModal() == .OK, let url = panel.url {
            Config.shared.mirrorRoot = url
            model.selectedFolder = nil
            model.flash("Mirroring \(url.lastPathComponent)")
        }
        NSApp.setActivationPolicy(.accessory)
    }
}
