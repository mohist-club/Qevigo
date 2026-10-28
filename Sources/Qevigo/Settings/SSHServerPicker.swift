import AppKit
import QevigoCore
import SwiftUI

/// Picks a host from ~/.ssh/config (or takes one typed by hand) and turns it
/// into a shortcut binding. Authentication is left to ssh: the sheet offers to
/// install a public key so the server stops asking for a password.
struct SSHServerPicker: View {
    let onPick: (LaunchBinding) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var hosts: [SSHHost] = []
    @State private var selection: String?
    @State private var manualAlias = ""
    @State private var opener: SSHOpener = .terminal
    @State private var remotePath = ""
    @State private var publicKeys: [SSHPublicKey] = []
    @State private var selectedKey = ""
    @State private var keyNotice: String?

    private var alias: String {
        (selection ?? manualAlias).trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool { LaunchBinding.isValidHostAlias(alias) }

    private var isDefaultKeySelected: Bool {
        publicKeys.first { $0.path == selectedKey }?.isDefaultIdentity ?? true
    }

    private var defaultKeyHint: String {
        isDefaultKeySelected
            ? tr("在终端运行一次 ssh-copy-id，输入一次密码后即可免密连接。",
                 "Runs ssh-copy-id once in Terminal: enter the password one time, then connect without it.")
            : tr("这不是 ssh 的默认密钥：装上之后还要在 ~/.ssh/config 里为该主机加一行 IdentityFile，ssh 才会使用它。",
                 "This is not one of ssh's default identities: after installing it, add an IdentityFile line for this host in ~/.ssh/config, or ssh will not use it.")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("添加 SSH 服务器", "Add SSH Server")).font(.headline)
                Text(tr(
                    "按快捷键即可连接。认证完全交给 ssh，Qevigo 不保存你的密码。",
                    "Press the shortcut to connect. Authentication is handled by ssh; Qevigo never stores your password."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()

            if hosts.isEmpty {
                emptyHostList
            } else {
                List(hosts, selection: $selection) { host in
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.alias)
                            if !host.detail.isEmpty {
                                Text(host.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .tag(host.alias)
                }
                .listStyle(.inset)
                .frame(height: 150)
            }

            Divider()
            Form {
                if !hosts.isEmpty {
                    LabeledContent(tr("或手动输入", "Or enter manually")) {
                        TextField("", text: $manualAlias, prompt: Text("user@example.com"))
                            .labelsHidden()
                            .frame(width: 230)
                            .onChange(of: manualAlias) { _, value in
                                if !value.isEmpty { selection = nil }
                            }
                    }
                }
                Picker(tr("打开方式", "Open With"), selection: $opener) {
                    ForEach(SSHOpener.allCases) { Text($0.localizedName).tag($0) }
                }
                .frame(width: 320)
                if opener == .visualStudioCode {
                    LabeledContent(tr("远程目录", "Remote Folder")) {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("", text: $remotePath, prompt: Text("~"))
                                .labelsHidden()
                                .frame(width: 230)
                            Text(tr("需要 VS Code 的 Remote-SSH 扩展。", "Requires the Remote-SSH extension in VS Code."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent(tr("免密登录", "Passwordless Login")) {
                    VStack(alignment: .leading, spacing: 4) {
                        if publicKeys.count > 1 {
                            Picker("", selection: $selectedKey) {
                                ForEach(publicKeys) { Text($0.label).tag($0.path) }
                            }
                            .labelsHidden()
                            .frame(width: 400)
                        }
                        HStack(spacing: 8) {
                            Button(tr("安装密钥…", "Install Key…")) {
                                ActionLauncher.installSSHKey(alias: alias, publicKey: selectedKey)
                                keyNotice = tr(
                                    "已在终端运行 ssh-copy-id，请在那里输入一次服务器密码。",
                                    "ssh-copy-id is running in Terminal; enter the server password there once."
                                )
                            }
                            .disabled(!isValid || selectedKey.isEmpty)
                            Spacer(minLength: 0)
                        }
                        Text(keyNotice ?? defaultKeyHint)
                        .font(.caption)
                        .foregroundStyle(keyNotice == nil ? (isDefaultKeySelected ? Color.secondary : Color.orange) : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
            }
            .formStyle(.columns)
            .padding(16)

            Divider()
            HStack {
                if !alias.isEmpty, !isValid {
                    Label(tr("主机别名含有不允许的字符", "The host alias contains characters that are not allowed"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("添加", "Add")) {
                    onPick(LaunchBinding(
                        name: alias, payload: alias, kind: .ssh,
                        sshOpener: opener,
                        sshRemotePath: opener == .visualStudioCode ? remotePath : nil
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 520)
        .task {
            hosts = SSHConfig.hosts()
            selection = hosts.first?.alias
            publicKeys = SSHPublicKey.available()
            selectedKey = publicKeys.first?.path ?? ""
        }
    }

    private var emptyHostList: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(tr("~/.ssh/config 里没有可用的主机", "No hosts found in ~/.ssh/config"))
                .foregroundStyle(.secondary)
            TextField("", text: $manualAlias, prompt: Text("user@example.com"))
                .labelsHidden()
                .frame(width: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
