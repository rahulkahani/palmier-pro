import SwiftUI

struct TimelineTileView: View {
    let timeline: Timeline
    let posterImage: NSImage?
    let isSelected: Bool
    let isActive: Bool
    let canDelete: Bool
    @Binding var isRenaming: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var renameDraft: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    @State private var lastClickTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color(white: 1.0, opacity: AppTheme.Opacity.subtle))
                if let posterImage {
                    GeometryReader { geo in
                        Image(nsImage: posterImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                if timeline.totalFrames > 0 {
                    durationBadge
                }
                if posterImage != nil {
                    timelineBadge
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(isSelected ? AppTheme.Accent.primary : Color.clear, lineWidth: AppTheme.BorderWidth.thick)
            )
            .contentShape(Rectangle())

            ZStack(alignment: .leading) {
                if isRenaming {
                    TextField("Timeline", text: $renameDraft)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($isRenameFieldFocused)
                        .onSubmit { commit() }
                        .onChange(of: isRenameFieldFocused) { _, focused in
                            if !focused { commit() }
                        }
                        .onExitCommand { onCancelRename() }
                } else {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        if isActive {
                            Circle()
                                .fill(AppTheme.Accent.primary)
                                .frame(width: AppTheme.Spacing.xs, height: AppTheme.Spacing.xs)
                        }
                        Text(timeline.name)
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isRenaming ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { handleClick() }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Rename") { beginRename() }
            Button("Duplicate") { onDuplicate() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
                .disabled(!canDelete)
        }
        .onChange(of: isRenaming) { _, newValue in
            if newValue {
                renameDraft = timeline.name
                DispatchQueue.main.async { isRenameFieldFocused = true }
            }
        }
    }

    // Matches AssetThumbnailView: type badge top-leading, duration bottom-trailing.
    private var timelineBadge: some View {
        VStack {
            HStack {
                Image(systemName: "film.stack")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(isActive ? AppTheme.Accent.primary : .white)
                    .padding(AppTheme.Spacing.xxs + AppTheme.Spacing.xxs)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(AppTheme.Spacing.xs)
                Spacer()
            }
            Spacer()
        }
    }

    private var durationBadge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(formatTimecode(frame: timeline.totalFrames, fps: timeline.fps))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(AppTheme.Spacing.xs)
            }
        }
    }

    private func beginRename() {
        renameDraft = timeline.name
        isRenaming = true
    }

    private func handleClick() {
        let now = Date()
        if let last = lastClickTime, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            onOpen()
            lastClickTime = nil
        } else {
            onTap()
            lastClickTime = now
        }
    }

    private func commit() {
        guard isRenaming else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == timeline.name {
            onCancelRename()
        } else {
            onCommitRename(trimmed)
        }
    }
}

struct TimelineDragPreview: View {
    let name: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "film.stack")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.primary)
            Text(name)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }
}
