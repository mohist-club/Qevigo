import AppKit
import QevigoCore
import SwiftUI

struct AdvancedTab: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var confirmReset = false
    @State private var legacy: LegacyImport.Snapshot?
    @State private var importMessage: String?

    private static let timeoutChoices: [Double] = [4, 6, 8, 10, 15]

    var body: some View {
        SettingsPage {
            Form {
                LabeledContent(tr("翻译提示词", "Translation Prompt")) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $store.translation.systemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 360, height: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.7))
                        HStack {
                            FormNote(tr("只影响 AI 模型的翻译风格与格式；目标语言由程序指定。", "Affects style and format for AI models only; the target language is set by the app."))
                            Spacer(minLength: 8)
                            Button(tr("恢复默认", "Restore Default")) {
                                store.translation.systemPrompt = PromptBuilder.defaultSystemPrompt
                            }
                        }
                        .frame(width: 360)
                    }
                }

                Divider().padding(.vertical, 6)

                LabeledContent(tr("首字等待时间", "First-Token Timeout")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: timeoutBinding) {
                            Text(tr("自动（按服务）", "Automatic (per service)")).tag(0.0)
                            ForEach(Self.timeoutChoices, id: \.self) { Text(tr("\(Int($0)) 秒", "\(Int($0)) s")).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: SettingsMetrics.fieldWidth)
                        FormNote(tr(
                            "服务在该时间内没有开始返回译文，就视为无响应并切换到下一个服务。",
                            "If a service has not started answering within this time it is treated as unresponsive and the next service is tried."
                        ))
                    }
                }

                LabeledContent(tr("玻璃透明度", "Glass Transparency")) {
                    HStack(spacing: 12) {
                        Slider(value: $store.preferences.glassTransparency, in: 0.15...0.85)
                            .frame(width: 200)
                            .disabled(!store.preferences.glassEffectEnabled)
                        Text("\(Int(store.preferences.glassTransparency * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Divider().padding(.vertical, 6)

                LabeledContent(tr("数据", "Data")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let legacy {
                            HStack(spacing: 8) {
                                Button(tr("从原版 Poptro 导入配置…", "Import from Original Poptro…")) { runImport(legacy) }
                                if let importMessage {
                                    Label(importMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                }
                            }
                        }
                        HStack {
                            Button(tr("在 Finder 中显示配置文件夹", "Show Config Folder in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([store.files.directory])
                            }
                            Button(tr("重置所有设置…", "Reset All Settings…"), role: .destructive) { confirmReset = true }
                        }
                        FormNote(tr(
                            "API Key 经 AES-GCM 加密保存在本机，不会上传。重置会同时清除所有 API Key。",
                            "API keys are AES-GCM encrypted on this Mac and never uploaded. Resetting also removes all API keys."
                        ))
                    }
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(width: 640)
        }
        .onAppear {
            let snapshot = LegacyImport.load()
            legacy = snapshot.isEmpty ? nil : snapshot
        }
        .confirmationDialog(
            tr("重置所有设置？", "Reset all settings?"), isPresented: $confirmReset, titleVisibility: .visible
        ) {
            Button(tr("重置", "Reset"), role: .destructive) { store.resetAll() }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("此操作会删除所有偏好设置、快捷键和 API Key，且无法撤销。", "This deletes all preferences, shortcuts and API keys and cannot be undone."))
        }
    }

    private func runImport(_ snapshot: LegacyImport.Snapshot) {
        let summary = store.importLegacy(snapshot)
        importMessage = tr(
            "已导入 \(summary.services) 个服务、\(summary.keys) 个 API Key、\(summary.shortcuts) 个快捷键",
            "Imported \(summary.services) services, \(summary.keys) API keys, \(summary.shortcuts) shortcuts"
        )
    }

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { store.translation.failover.firstTokenTimeoutOverride ?? 0 },
            set: { store.translation.failover.firstTokenTimeoutOverride = $0 == 0 ? nil : $0 }
        )
    }
}
