import AppKit
import QevigoCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds an OpenVPN configuration as a shortcut: pick an .ovpn file, name it,
/// and optionally set up passwordless sudo so the hotkey connects silently.
struct VPNConfigPicker: View {
    let existing: [LaunchBinding]
    let onPick: (LaunchBinding) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sourceURL: URL?
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var installedConfig: String?
    @State private var sudoersInstalled = VPNService.hasPasswordlessRules

    private var binaryPath: String? { OpenVPN.installedBinary() }
    private var isValid: Bool { sourceURL != nil && OpenVPN.isValidConfigName(name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                LabeledContent(tr("openvpn 命令行", "openvpn CLI")) {
                    if let binaryPath {
                        HStack(spacing: 6) {
                            StatusChip(title: tr("已安装", "Installed"), isGood: true)
                            Text(binaryPath).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            StatusChip(title: tr("未安装", "Not installed"), isGood: false)
                            HStack(spacing: 8) {
                                Text("brew install openvpn").font(.system(.caption, design: .monospaced))
                                Button(tr("在终端中安装", "Install in Terminal")) {
                                    VPNService.openInTerminal(command: "brew install openvpn")
                                }
                            }
                            FormNote(tr(
                                "openvpn 命令行本身就是完整客户端，不需要再装图形版。",
                                "The openvpn CLI is a complete client; no GUI app is needed."
                            ))
                        }
                    }
                }

                LabeledContent(tr("配置文件", "Configuration")) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button(tr("选择 .ovpn 文件…", "Choose .ovpn File…")) { chooseFile() }
                            if let sourceURL {
                                Text(sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        FormNote(tr(
                            "文件会被复制到 ~/.qevigo/vpn/ 并设为仅本人可读（里面有你的私钥）。",
                            "The file is copied to ~/.qevigo/vpn/ with owner-only permissions; it contains your private key."
                        ))
                    }
                }

                LabeledContent(tr("名称", "Name")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $name, prompt: Text("office-vpn"))
                            .labelsHidden()
                            .frame(width: 230)
                        if !name.isEmpty, !OpenVPN.isValidConfigName(name) {
                            Text(tr("只能使用字母、数字、- 和 _", "Use letters, digits, - and _ only"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                Divider().padding(.vertical, 4)

                LabeledContent(tr("免密连接", "Passwordless")) {
                    VStack(alignment: .leading, spacing: 5) {
                        if sudoersInstalled {
                            StatusChip(title: tr("已配置", "Configured"), isGood: true)
                        } else {
                            StatusChip(title: tr("未配置", "Not configured"), isGood: false)
                        }
                        FormNote(tr(
                            "建立 VPN 隧道需要管理员权限。未配置时，每次连接都会打开终端让你输入 Mac 密码；配置一次之后，按快捷键即可直接连接。",
                            "Creating a VPN tunnel requires administrator rights. Without this, every connection opens Terminal to ask for your Mac password; set it up once and the shortcut connects directly."
                        ))
                        if sudoersInstalled {
                            Button(tr("取消免密（恢复每次询问）", "Remove passwordless access")) {
                                VPNService.openInTerminal(command: OpenVPN.removeSudoersCommand())
                                sudoersInstalled = false
                            }
                        }
                    }
                }
            }
            .formStyle(.columns)
            .padding(16)

            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear { sudoersInstalled = VPNService.hasPasswordlessRules }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tr("添加 VPN 配置", "Add VPN Configuration")).font(.headline)
            Text(tr(
                "通过 openvpn 命令行连接。按一次快捷键连接，再按一次断开。",
                "Connects through the openvpn CLI. Press the shortcut to connect, press it again to disconnect."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let installedConfig {
                Label(
                    tr("已添加，配置在 \((installedConfig as NSString).lastPathComponent)", "Added as \((installedConfig as NSString).lastPathComponent)"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption).foregroundStyle(.green)
            }
            Spacer()
            Button(tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(tr("添加", "Add")) { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(12)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data]
        panel.prompt = tr("选择", "Choose")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
        errorMessage = nil
        if name.isEmpty {
            let suggestion = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
            name = OpenVPN.isValidConfigName(suggestion) ? suggestion : "vpn"
        }
    }

    private func add() {
        guard let sourceURL else { return }
        do {
            let path = try VPNConfigStore.install(source: sourceURL, name: name.trimmingCharacters(in: .whitespaces))
            installedConfig = path
            let binding = LaunchBinding(name: name, payload: path, kind: .vpn)
            onPick(binding)
            // Rules name every managed config, so they are rebuilt with this one included.
            if let command = VPNConfigStore.sudoersInstallCommand(for: existing + [binding]) {
                VPNService.openInTerminal(command: command, note: tr(
                    "输入你的 Mac 密码以启用免密连接（只需这一次）。",
                    "Enter your Mac password once to enable passwordless connections."
                ))
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
