import AppKit
import QevigoCore
import SwiftUI

enum SettingsMetrics {
    static let fieldWidth: CGFloat = 260
}

struct FormNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
    }
}

/// Green/orange status capsule used for permissions and service state.
struct StatusChip: View {
    let title: String
    let isGood: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGood ? Color.green : Color.orange)
            Text(title)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct SettingsPage<Content: View>: View {
    @EnvironmentObject private var store: SettingsStore
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .id(store.preferences.interfaceLanguage)
    }
}
