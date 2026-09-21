import AppKit
import QevigoCore
import SwiftUI

struct AboutTab: View {
    var body: some View {
        SettingsPage {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                Text(AppInfo.name).font(.title2.weight(.semibold)).padding(.top, 10)
                Text(tr("版本 \(AppInfo.version)（\(AppInfo.build)）", "Version \(AppInfo.version) (\(AppInfo.build))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(tr("选中文字，按一下快捷键，立即翻译。", "Select text, press a shortcut, get the translation."))
                    .font(.callout)
                    .padding(.top, 10)

                Form {
                    LabeledContent(tr("开源协议", "License"), value: "MIT")
                    LabeledContent(tr("系统要求", "Requires"), value: tr("macOS 14 或更高版本", "macOS 14 or later"))
                    if UpdateChecker.isAvailable {
                        LabeledContent(tr("软件更新", "Software Update")) {
                            Button(tr("检查更新…", "Check for Updates…")) { Task { await UpdateChecker.check(silentWhenCurrent: false) } }
                        }
                    }
                    LabeledContent(tr("原项目", "Original Project")) {
                        Link("github.com/mohist-club/Poptro", destination: AppInfo.originalProject)
                    }
                }
                .formStyle(.columns)
                .padding(.top, 20)
                .frame(width: 440)

                Label(
                    tr("API Key 与个人配置仅保存在当前 Mac，并在本地加密。", "API keys and personal settings stay on this Mac, encrypted."),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 18)

                Text(tr("基于 Poptro（MIT）重构。", "Based on Poptro (MIT)."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 28)
            .frame(width: 640)
        }
    }
}
