import AppKit
import KeyboardShortcuts
import PoptroCore
import SwiftUI

private enum ShortcutRowID: Hashable {
    case translate
    case binding(UUID)
}

private enum AddSheet: String, Identifiable {
    case application, shortcut, system, script
    var id: String { rawValue }
}

struct ShortcutsTab: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var selection: ShortcutRowID?
    @State private var sheet: AddSheet?
    @State private var refresh = 0

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 12) {
                FormNote(tr(
                    "为应用、快捷指令、系统操作或脚本绑定全局快捷键。在快捷键框中按 ⌫ 可清除。",
                    "Bind global shortcuts to apps, Shortcuts, system actions or scripts. Press ⌫ in a shortcut box to clear it."
                ))

                List(selection: $selection) {
                    row(
                        icon: AnyView(Image(systemName: "character.cursor.ibeam").resizable().scaledToFit().foregroundStyle(.secondary)),
                        title: tr("划词翻译", "Translate Selection"),
                        subtitle: tr("内置", "Built-in"),
                        name: .translateSelection,
                        isEnabled: $store.preferences.translateShortcutEnabled
                    )
                    .tag(ShortcutRowID.translate)

                    ForEach($store.bindings) { $binding in
                        row(
                            icon: icon(for: binding),
                            title: binding.name,
                            subtitle: subtitle(for: binding),
                            name: KeyboardShortcuts.Name(binding.hotkeyName),
                            isEnabled: $binding.isEnabled
                        )
                        .tag(ShortcutRowID.binding(binding.id))
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 300)

                HStack(spacing: 8) {
                    Menu {
                        Button { sheet = .application } label: { Label(tr("应用…", "Application…"), systemImage: "app") }
                        Button { sheet = .shortcut } label: { Label(tr("快捷指令…", "Shortcut…"), systemImage: "square.stack.3d.up") }
                        Button { sheet = .system } label: { Label(tr("系统操作…", "System Action…"), systemImage: "gearshape.2") }
                        Button { sheet = .script } label: { Label(tr("脚本…", "Script…"), systemImage: "terminal") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderedButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selectedBinding == nil)
                        .help(tr("删除所选快捷键", "Delete Selected Shortcut"))

                    Spacer()
                    FormNote(tr("共 \(store.bindings.count + 1) 个", "\(store.bindings.count + 1) total"))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(width: 640)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .application: ApplicationPicker { add($0) }
            case .shortcut: ShortcutsPicker { add($0) }
            case .system: SystemActionPicker { add($0) }
            case .script: ScriptEditor { add($0) }
            }
        }
    }

    private var selectedBinding: LaunchBinding? {
        guard case .binding(let id) = selection else { return nil }
        return store.bindings.first { $0.id == id }
    }

    private func add(_ binding: LaunchBinding) {
        store.bindings.append(binding)
        selection = .binding(binding.id)
    }

    private func removeSelected() {
        guard let binding = selectedBinding else { return }
        KeyboardShortcuts.reset(KeyboardShortcuts.Name(binding.hotkeyName))
        store.bindings.removeAll { $0.id == binding.id }
        selection = nil
    }

    private func row(
        icon: AnyView, title: String, subtitle: String, name: KeyboardShortcuts.Name, isEnabled: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            ShortcutField(name: name, width: 150)
            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private func icon(for binding: LaunchBinding) -> AnyView {
        switch binding.kind {
        case .application:
            return AnyView(Image(nsImage: NSWorkspace.shared.icon(forFile: binding.payload)).resizable())
        case .shortcut:
            return AnyView(Image(systemName: "square.stack.3d.up").resizable().scaledToFit().foregroundStyle(.secondary))
        case .system:
            return AnyView(Image(systemName: "gearshape.2").resizable().scaledToFit().foregroundStyle(.secondary))
        case .script:
            return AnyView(Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(.secondary))
        }
    }

    private func subtitle(for binding: LaunchBinding) -> String {
        switch binding.kind {
        case .application: return tr("打开应用", "Open Application")
        case .shortcut: return tr("运行快捷指令", "Run Shortcut")
        case .system: return tr("系统操作", "System Action")
        case .script:
            switch binding.scriptKind ?? .shell {
            case .shell: return "Shell"
            case .appleScript: return "AppleScript"
            case .javaScript: return "JavaScript for Automation"
            }
        }
    }
}

// MARK: - Sheets

private struct SheetFrame<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            content
            Divider()
            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }
}

private struct ApplicationPicker: View {
    let onPick: (LaunchBinding) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [(name: String, path: String)] = []
    @State private var query = ""

    var body: some View {
        SheetFrame(title: tr("选择应用", "Choose Application"), subtitle: tr("按下快捷键时打开所选应用。", "The app opens when the shortcut is pressed.")) {
            VStack(spacing: 0) {
                TextField(tr("搜索应用", "Search Apps"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                List(filtered, id: \.path) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onPick(LaunchBinding(name: app.name, payload: app.path, kind: .application))
                        dismiss()
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 440, height: 460)
        .task { apps = ActionLauncher.installedApplications() }
    }

    private var filtered: [(name: String, path: String)] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct ShortcutsPicker: View {
    let onPick: (LaunchBinding) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        SheetFrame(title: tr("选择快捷指令", "Choose Shortcut"), subtitle: tr("从「快捷指令」App 读取。", "Loaded from the Shortcuts app.")) {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button(tr("重新读取", "Retry")) { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(names, id: \.self) { name in
                        Label(name, systemImage: "square.stack.3d.up")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPick(LaunchBinding(name: name, payload: name, kind: .shortcut))
                                dismiss()
                            }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(width: 440, height: 420)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        do { names = try await ActionLauncher.shortcutNames() } catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

private struct SystemActionPicker: View {
    let onPick: (LaunchBinding) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(title: tr("选择系统操作", "Choose System Action"), subtitle: tr("危险操作会在执行前再次确认。", "Destructive actions always ask for confirmation.")) {
            List(SystemShortcutAction.allCases) { action in
                Label(name(action), systemImage: symbol(action))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onPick(LaunchBinding(name: name(action), payload: action.rawValue, kind: .system))
                        dismiss()
                    }
            }
            .listStyle(.inset)
        }
        .frame(width: 440, height: 390)
    }

    private func name(_ action: SystemShortcutAction) -> String {
        switch action {
        case .lockScreen: return tr("锁定屏幕", "Lock Screen")
        case .sleep: return tr("进入睡眠", "Sleep")
        case .emptyTrash: return tr("清空废纸篓", "Empty Trash")
        case .logOut: return tr("退出登录", "Log Out")
        case .restart: return tr("重新启动", "Restart")
        case .shutDown: return tr("关机", "Shut Down")
        }
    }

    private func symbol(_ action: SystemShortcutAction) -> String {
        switch action {
        case .lockScreen: return "lock"
        case .sleep: return "moon.zzz"
        case .emptyTrash: return "trash"
        case .logOut: return "rectangle.portrait.and.arrow.right"
        case .restart: return "arrow.clockwise"
        case .shutDown: return "power"
        }
    }
}

private struct ScriptEditor: View {
    let onPick: (LaunchBinding) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ShortcutScriptKind = .shell
    @State private var source = ""

    var body: some View {
        SheetFrame(title: tr("添加脚本", "Add Script"), subtitle: tr("脚本仅保存在这台 Mac，并以当前用户身份运行。", "The script stays on this Mac and runs as the current user.")) {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    TextField(tr("名称", "Name"), text: $name)
                    Picker(tr("脚本类型", "Script Type"), selection: $kind) {
                        Text("Shell").tag(ShortcutScriptKind.shell)
                        Text("AppleScript").tag(ShortcutScriptKind.appleScript)
                        Text("JavaScript for Automation").tag(ShortcutScriptKind.javaScript)
                    }
                    LabeledContent(tr("脚本", "Script")) {
                        TextEditor(text: $source)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 330, height: 170)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 0.6))
                    }
                }
                .formStyle(.columns)

                HStack {
                    Spacer()
                    Button(tr("添加", "Add")) {
                        onPick(LaunchBinding(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines), payload: source,
                            kind: .script, scriptKind: kind
                        ))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 540, height: 470)
    }
}
