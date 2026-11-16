import AppKit
import QevigoCore
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let top = max(40, size.height * 0.055)
            let searchBlock = top + 30 + 28
            let dotsBlock: CGFloat = 72
            let gridHeight = max(200, size.height - searchBlock - dotsBlock)

            ZStack {
                // Empty space anywhere closes the grid, as it did in Launchpad.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onDismiss() }

                VStack(spacing: 0) {
                    searchField
                        .padding(.top, top)
                        .padding(.bottom, 28)
                    ZStack {
                        pager(width: size.width, height: gridHeight)
                        if model.isSearching && model.results.isEmpty {
                            Text(tr("没有找到「\(model.query)」", "No apps match “\(model.query)”"))
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(height: gridHeight)
                    pageDots.frame(height: dotsBlock)
                }
                // Pinned to the top, so the search field stays put when a
                // search leaves a single page or nothing at all.
                .frame(width: size.width, height: size.height, alignment: .top)
            }
            .scaleEffect(model.appeared ? 1 : 1.07)
            .opacity(model.appeared ? 1 : 0)
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

    private func pager(width: CGFloat, height: CGFloat) -> some View {
        let inset = max(40, width * 0.09)
        let cell = CGSize(
            width: (width - inset * 2) / CGFloat(model.grid.columns),
            height: height / CGFloat(model.grid.rows)
        )
        let iconSide = min(cell.width * 0.55, cell.height * 0.62, 128)
        return HStack(spacing: 0) {
            ForEach(Array(model.pages.enumerated()), id: \.offset) { index, apps in
                PageGrid(
                    model: model, apps: apps, firstIndex: index * model.grid.perPage,
                    cell: cell, iconSide: iconSide
                )
                .padding(.horizontal, inset)
                .frame(width: width, height: height)
            }
        }
        .offset(x: -CGFloat(model.page) * width)
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
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
}

private struct PageGrid: View {
    @ObservedObject var model: LauncherModel
    let apps: [AppEntry]
    let firstIndex: Int
    let cell: CGSize
    let iconSide: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<model.grid.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<model.grid.columns, id: \.self) { column in
                        let index = row * model.grid.columns + column
                        if index < apps.count {
                            AppCell(
                                model: model, entry: apps[index],
                                isSelected: model.selection == firstIndex + index,
                                iconSide: iconSide, labelWidth: cell.width - 16
                            )
                            .frame(width: cell.width, height: cell.height)
                        } else {
                            Color.clear.frame(width: cell.width, height: cell.height)
                        }
                    }
                }
            }
        }
    }
}

private struct AppCell: View {
    @ObservedObject var model: LauncherModel
    let entry: AppEntry
    let isSelected: Bool
    let iconSide: CGFloat
    let labelWidth: CGFloat

    var body: some View {
        Button { model.launch(entry) } label: {
            VStack(spacing: 8) {
                Image(nsImage: model.icon(for: entry))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSide, height: iconSide)
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: labelWidth)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.2 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDarkens())
        .help(entry.name)
    }
}

/// Launchpad darkened an icon while it was held down.
private struct PressDarkens: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? -0.3 : 0)
    }
}
