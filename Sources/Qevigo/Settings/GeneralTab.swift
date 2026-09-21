import AppKit
import KeyboardShortcuts
import QevigoCore
import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var accessibilityGranted = PermissionService.isAccessibilityTrusted

    var body: some View {
        SettingsPage {
            Form {
                LabeledContent(tr("开机时启动", "Launch at Login")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(tr("开启", "On"), isOn: launchBinding)
                        if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                    }
                }

                LabeledContent(tr("划词翻译快捷键", "Translate Shortcut")) {
                    HStack(spacing: 12) {
                        ShortcutField(name: .translateSelection, width: 200)
                        Toggle(tr("启用", "Enabled"), isOn: $store.preferences.translateShortcutEnabled)
                    }
                }

                Divider().padding(.vertical, 6)

                LabeledContent(tr("界面语言", "Interface Language")) {
                    Picker("", selection: $store.preferences.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases) { Text($0.nativeName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.fieldWidth)
                }

                LabeledContent(tr("外观", "Appearance")) {
                    Picker("", selection: $store.preferences.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.localizedName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: SettingsMetrics.fieldWidth)
                }

                LabeledContent(tr("窗口玻璃效果", "Window Glass Effect")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(tr("开启", "On"), isOn: $store.preferences.glassEffectEnabled)
                        FormNote(tr("外观设置适用于所有 Qevigo 窗口。", "Appearance applies to all Qevigo windows."))
                    }
                }

                Divider().padding(.vertical, 6)

                LabeledContent(tr("所需权限", "Required Access")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            StatusChip(title: tr("辅助功能", "Accessibility"), isGood: accessibilityGranted)
                            Button(tr("前往系统设置", "Open System Settings")) {
                                if !PermissionService.requestAccessibility() { PermissionService.openAccessibilitySettings() }
                            }
                        }
                        FormNote(tr(
                            "Qevigo 需要「辅助功能」来读取选中的文字并响应快捷键，不会记录或上传你的内容。",
                            "Qevigo needs Accessibility to read selected text and respond to shortcuts. It never records or uploads your content."
                        ))
                    }
                }

                Divider().padding(.vertical, 6)

                LabeledContent(tr("默认翻译服务", "Default Service")) {
                    Picker("", selection: $store.translation.defaultProvider) {
                        ForEach(providerChoices) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.fieldWidth)
                }

                LabeledContent(tr("默认目标语言", "Default Target Language")) {
                    Picker("", selection: $store.translation.primaryLanguageCode) {
                        ForEach(Languages.all) { Text($0.localizedName).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.fieldWidth)
                }

                LabeledContent(tr("备用语言", "Secondary Language")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $store.translation.secondaryLanguageCode) {
                            ForEach(Languages.all) { Text($0.localizedName).tag($0.code) }
                        }
                        .labelsHidden()
                        .frame(width: SettingsMetrics.fieldWidth)
                        FormNote(tr(
                            "原文已是默认目标语言时，改为翻译成备用语言。",
                            "Used when the source text is already in the default target language."
                        ))
                    }
                }

                if AppInfo.updateRepository != nil {
                    LabeledContent(tr("自动检查更新", "Check for Updates")) {
                        Toggle(tr("开启", "On"), isOn: $store.preferences.automaticUpdateChecks)
                    }
                }

                Divider().padding(.vertical, 6)

                LabeledContent(tr("帮助与反馈", "Help & Feedback")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Link("GitHub Issues", destination: AppInfo.issuesURL)
                        FormNote(tr("隐私：所有设置仅保存在这台 Mac 上。", "Privacy: all settings are stored only on this Mac."))
                    }
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(width: 640)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = PermissionService.isAccessibilityTrusted
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// The default service can only be one that is usable, but keep the saved
    /// value visible so the picker never shows an empty selection.
    private var providerChoices: [ProviderID] {
        var choices = store.availableProviders
        if !choices.contains(store.translation.defaultProvider) { choices.insert(store.translation.defaultProvider, at: 0) }
        return choices
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LaunchAtLogin.set(newValue)
                    launchError = nil
                } catch {
                    launchError = error.localizedDescription
                }
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        )
    }
}
