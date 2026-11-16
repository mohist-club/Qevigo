import AppKit
import QevigoCore
import SwiftUI

struct LauncherView: View {
    /// Drag locations and cell positions share this space: the screen, top left at zero.
    static let space = "launcher"

    @ObservedObject var model: LauncherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Empty space anywhere closes the grid, as it did in Launchpad.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onDismiss() }

                VStack(spacing: 0) {
                    searchField.padding(.top, model.searchTop)
                    Spacer(minLength: 0)
                    pageDots.frame(height: 72)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                grid

                if model.isSearching && model.results.isEmpty {
                    Text(tr("没有找到「\(model.query)」", "No apps match “\(model.query)”"))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                }

                if let folder = model.openFolder {
                    FolderOverlay(model: model, folder: folder)
                        .transition(.opacity)
                }

                draggedIcon
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .scaleEffect(model.appeared ? 1 : 1.07)
            .opacity(model.appeared ? 1 : 0)
            .onAppear { model.updateScreen(geometry.size) }
            .onChange(of: geometry.size) { _, size in model.updateScreen(size) }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.7))
            TextField("", text: $model.query, prompt: Text(tr("搜索", "Search")).foregroundStyle(.white.opacity(0.6)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($searchFocused)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(width: 250, height: 30)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
    }

    /// Every item is placed by identity, so a reorder slides icons to their
    /// new cells instead of swapping what the cells show.
    private var grid: some View {
        let metrics = model.metrics
        let perPage = model.grid.perPage
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                let center = metrics.center(of: index % perPage)
                let pageShift = CGFloat(index / perPage - model.page) * metrics.pageWidth
                ItemCell(model: model, item: item, isSelected: model.selection == index, folder: nil)
                    .frame(width: metrics.cell.width, height: metrics.cell.height)
                    .position(x: center.x + pageShift, y: center.y)
            }
        }
        .frame(width: model.screen.width, height: model.screen.height, alignment: .topLeading)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: model.page)
    }

    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<model.pageCount, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == model.page ? 0.95 : 0.35))
                    .frame(width: 8, height: 8)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { model.page = index }
            }
        }
        .opacity(model.pageCount > 1 ? 1 : 0)
    }

    /// The item being dragged, lifted and following the pointer.
    @ViewBuilder
    private var draggedIcon: some View {
        if let id = model.draggingID, let item = model.item(withID: id) {
            ItemIcon(model: model, item: item, side: model.iconSide)
                .scaleEffect(1.1)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                .position(model.dragPoint)
                .allowsHitTesting(false)
        }
    }
}

/// One app or folder: its icon and name. Click opens it; drag moves it.
private struct ItemCell: View {
    @ObservedObject var model: LauncherModel
    let item: LauncherItem
    let isSelected: Bool
    /// Set when the cell is inside this open folder.
    let folder: LauncherFolder?

    var body: some View {
        let isDragged = model.draggingID == item.id
        let isMergeTarget = model.mergeTargetID == item.id
        VStack(spacing: 8) {
            ItemIcon(model: model, item: item, side: model.iconSide)
                .background(
                    // Held over another app, this is where a folder will form.
                    RoundedRectangle(cornerRadius: model.iconSide * 0.26, style: .continuous)
                        .fill(Color.white.opacity(isMergeTarget ? 0.3 : 0))
                        .padding(-10)
                )
                .scaleEffect(isMergeTarget ? 1.1 : 1)
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: model.metrics.cell.width - 16)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.2 : 0))
        )
        .contentShape(Rectangle())
        // Not zero: the cell must keep receiving the drag it started.
        .opacity(isDragged ? 0.001 : 1)
        .gesture(drag.exclusively(before: TapGesture().onEnded { tap() }))
        .animation(.easeOut(duration: 0.15), value: isMergeTarget)
        .help(item.name)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(LauncherView.space))
            .onChanged { value in
                if folder != nil, let app = item.app {
                    model.folderDragChanged(path: app.path, to: value.location)
                } else {
                    model.dragChanged(id: item.id, to: value.location)
                }
            }
            .onEnded { _ in
                if folder != nil, let app = item.app {
                    model.folderDragEnded(path: app.path)
                } else {
                    model.dragEnded()
                }
            }
    }

    private func tap() {
        if folder != nil, let app = item.app {
            model.launch(app)
        } else {
            model.activate(item)
        }
    }
}

private struct ItemIcon: View {
    @ObservedObject var model: LauncherModel
    let item: LauncherItem
    let side: CGFloat

    var body: some View {
        switch item {
        case .app(let app):
            Image(nsImage: model.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        case .folder(let folder):
            FolderIcon(model: model, folder: folder, side: side)
        }
    }
}

/// A rounded square showing the first nine apps of a folder, three by three.
private struct FolderIcon: View {
    @ObservedObject var model: LauncherModel
    let folder: LauncherFolder
    let side: CGFloat

    var body: some View {
        // App icons leave a transparent margin around their artwork; the
        // folder's square matches the artwork, not the full icon frame.
        let box = side * 0.82
        let inner = box * 0.8
        let mini = inner / 3.3
        let gap = (inner - mini * 3) / 2
        ZStack {
            RoundedRectangle(cornerRadius: box * 0.24, style: .continuous)
                .fill(Color.white.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: box * 0.24, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                )
                .frame(width: box, height: box)
            VStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            if index < folder.apps.count {
                                Image(nsImage: model.icon(for: folder.apps[index]))
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: mini, height: mini)
                            } else {
                                Color.clear.frame(width: mini, height: mini)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }
}

/// An open folder: its name, editable, above its apps. Click outside to close;
/// drag an app out of the panel to take it out of the folder.
private struct FolderOverlay: View {
    @ObservedObject var model: LauncherModel
    let folder: LauncherFolder
    @State private var name = ""
    @FocusState private var editingName: Bool

    var body: some View {
        let geometry = model.folderGeometry(appCount: folder.apps.count)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .frame(width: model.screen.width, height: model.screen.height)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: geometry.frame.width, height: geometry.frame.height)
                // Clicks on the panel itself only end editing the name.
                .contentShape(Rectangle())
                .onTapGesture { editingName = false }
                .position(x: geometry.frame.midX, y: geometry.frame.midY)

            TextField("", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .focused($editingName)
                .onSubmit { commit() }
                .frame(width: max(120, geometry.frame.width - 80))
                .position(x: geometry.frame.midX, y: geometry.frame.minY + geometry.titleHeight / 2)

            ForEach(Array(folder.apps.enumerated()), id: \.element.id) { index, app in
                ItemCell(model: model, item: .app(app), isSelected: false, folder: folder)
                    .frame(width: geometry.metrics.cell.width, height: geometry.metrics.cell.height)
                    .position(geometry.metrics.center(of: index))
            }
        }
        .frame(width: model.screen.width, height: model.screen.height, alignment: .topLeading)
        .onAppear { name = folder.name }
        .onChange(of: folder.id) { _, _ in name = folder.name }
        .onDisappear { commit() }
    }

    private func commit() {
        model.renameFolder(folder.id, to: name)
    }

    private func close() {
        commit()
        model.closeFolder()
    }
}
