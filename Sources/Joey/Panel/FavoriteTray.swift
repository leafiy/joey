import AppKit
import LeafiyUI
import SwiftUI

/// The Favorite Tray (CONTEXT.md): a floating drop surface under the menu-bar
/// icon, shown while a drag hovers the icon and at least one Host is favorited.
/// Each favorite Host is one drop row; dropping uploads to its configured
/// landing directory.
@MainActor
final class FavoriteTrayController {
    private weak var model: JoeyModel?
    private var panel: LeafiyFloatingPanel?
    private var hideTask: Task<Void, Never>?

    init(model: JoeyModel) {
        self.model = model
    }

    func show() {
        cancelHide()
        guard let model, !model.settings.favoriteHosts.isEmpty else { return }
        let content = FavoriteTrayView(model: model)
        if let panel {
            panel.setContent(content)
        } else {
            panel = LeafiyFloatingPanel(
                configuration: LeafiyFloatingPanelConfiguration(
                    level: .popUpMenu,
                    isMovable: false,
                    identifier: "favorite-tray",
                    title: L("Favorites")),
                content: content)
        }
        guard let panel else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 120)
        var origin = NSPoint(x: 0, y: 0)
        if let anchor = LeafiyMenuBarDropTarget.statusItemScreenFrame() {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
                let limit = screen.visibleFrame
                origin.x = min(max(origin.x, limit.minX + 8), limit.maxX - size.width - 8)
                origin.y = max(origin.y, limit.minY + 8)
            }
        } else if let screen = NSScreen.main {
            origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Hides after a grace period so the drag can travel from the icon into
    /// the tray without the tray vanishing underneath it.
    func scheduleHide(after seconds: Double = 1.2) {
        cancelHide()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    func hide() {
        cancelHide()
        panel?.orderOut(nil)
    }

    /// Row-highlight relay: while any row is targeted the tray must stay up.
    func dragTargetChanged(_ inside: Bool) {
        if inside {
            cancelHide()
        } else {
            scheduleHide(after: 0.8)
        }
    }
}

struct FavoriteTrayView: View {
    @ObservedObject var model: JoeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.s) {
            Text(L("Drop to upload"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.settings.favoriteHosts) { host in
                FavoriteTrayRow(model: model, host: host)
            }
        }
        .padding(LeafiyDesign.Spacing.m)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LeafiyDesign.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: LeafiyDesign.Radius.panel)
                .strokeBorder(.quaternary)
        }
    }
}

private struct FavoriteTrayRow: View {
    @ObservedObject var model: JoeyModel
    let host: HostRecord
    @State private var targeted = false

    var body: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xxs) {
                Text(host.displayName)
                    .lineLimit(1)
                Text(host.favoriteDirectory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, LeafiyDesign.Spacing.s)
        .padding(.vertical, LeafiyDesign.Spacing.s)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: LeafiyDesign.Radius.control))
        .contentShape(Rectangle())
        .leafiyFileDrop(isTargeted: $targeted) { urls in
            model.favoriteDrop(urls, host: host)
        }
        .leafiyDropHighlight(targeted)
        .onChange(of: targeted) { _, inside in
            model.favoriteTray.dragTargetChanged(inside)
        }
    }
}
