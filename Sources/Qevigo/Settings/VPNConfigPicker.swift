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
    @State private var engineNote: String?
    @State private var engineTick = 0

    private var binaryPath: String? { VPNService.binary() }
    private var brewPath: String? { OpenVPN.installedBrew() }
    private var installButtonTitle: String {
        brewPath == nil
            ? tr("安装 Homebrew 和 openvpn…", "Install Homebrew and openvpn…")
            : tr("安装 openvpn…", "Install openvpn…")
    }
    private var isValid: Bool { sourceURL != nil && OpenVPN.isValidConfigName(name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                LabeledContent(tr("openvpn 引擎", "openvpn Engine")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let binaryPath {
                            HStack(spacing: 6) {
                                StatusChip(title: tr("已就绪", "Ready"), isGood: true)
                                Text(binaryPath).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        } else {
                            StatusChip(title: tr("未安装", "Not installed"), isGood: false)
                            HStack(spacing: 8) {
                                Button(installButtonTitle) { installEngine() }
                                Button(tr("指定已有的 openvpn…", "Choose Existing openvpn…")) { chooseBinary() }
                            }
                            FormNote(brewPath == nil
                                ? tr(
                                    "将依次安装 Homebrew 和 openvpn（会在终端里进行，需要输入一次 Mac 密码）。openvpn 命令行本身就是完整客户端，不需要图形版。",
                                    "Installs Homebrew and then openvpn in Terminal; it asks for your Mac password once. The openvpn CLI is a complete client, no GUI app needed."
                                )
                                : tr(
                                    "将通过 Homebrew 安装 openvpn（约 1 MB，在终端里进行）。openvpn 命令行本身就是完整客户端，不需要图形版。",
                                    "Installs openvpn through Homebrew (about 1 MB) in Terminal. The openvpn CLI is a complete client, no GUI app needed."
                                ))
                            if let engineNote {
                                Text(engineNote).font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360, alignment: .leading)
                            }
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
        .id(engineTick)
        .task {
            // The install runs in Terminal, so watch for the binary appearing.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                sudoersInstalled = VPNService.hasPasswordlessRules
                engineTick += 1
            }
        }
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

    private func installEngine() {
        engineNote = tr(
            "正在终端里安装，完成后这里会自动变成「已就绪」。",
            "Installing in Terminal; this turns into “Ready” when it finishes."
        )
        VPNService.openInTerminal(command: OpenVPN.installCommand(brew: brewPath))
    }

    /// For openvpn installed somewhere unusual, e.g. MacPorts or by hand.
    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/sbin")
        panel.prompt = tr("选择", "Choose")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let output = (try? await ActionLauncher.runSpec(OpenVPN.versionSpec(binary: url.path))) ?? ""
            if OpenVPN.isOpenVPNVersionOutput(output) {
                AppEnvironment.shared.settings.preferences.openvpnPath = url.path
                engineNote = nil
                engineTick += 1
            } else {
                engineNote = tr(
                    "这个文件不是 openvpn 客户端。",
                    "That file is not an openvpn client."
                )
            }
        }
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
