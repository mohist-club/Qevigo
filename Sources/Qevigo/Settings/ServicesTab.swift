import AppKit
import QevigoCore
import SwiftUI

struct ServicesTab: View {
    @EnvironmentObject private var store: SettingsStore
    let health: ProviderHealth

    @State private var selected: ProviderID = .zhipu
    @State private var keyDraft = ""
    @State private var discovered: [ProviderID: [String]] = [:]
    @State private var isLoadingModels = false
    @State private var isTesting = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 14) {
                failoverHeader

                HStack(alignment: .top, spacing: 16) {
                    providerList
                    detail
                }
                .frame(height: 430)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(width: 640)
        }
        .onAppear {
            selected = store.effectiveProvider ?? store.translation.defaultProvider
            loadDraft()
        }
        .onChange(of: selected) { _, _ in
            loadDraft()
            message = nil
        }
    }

    // MARK: Failover

    private var failoverHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(tr("自动故障转移", "Automatic Failover"), isOn: $store.translation.failover.isEnabled)
                .font(.headline)
            FormNote(tr(
                "当前服务限流、额度用尽或长时间没有响应时，自动改用列表中下一个可用的服务。拖动左侧列表可调整优先级，出错的服务会暂时跳过。",
                "When the current service is rate limited, out of quota or not responding, the next available service in the list is used. Drag to reorder priority; failing services are skipped for a while."
            ))
        }
    }

    // MARK: List

    private var providerList: some View {
        List(selection: $selected) {
            ForEach(store.translation.failover.order) { id in
                providerRow(id).tag(id)
            }
            .onMove { store.translation.failover.order.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(width: 216)
    }

    private func providerRow(_ id: ProviderID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: id.symbol)
                .frame(width: 20)
                .foregroundStyle(store.isAvailable(id) ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(id.displayName).lineLimit(1)
                    if id == store.translation.defaultProvider {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
                            .help(tr("默认服务", "Default Service"))
                    }
                }
                rowStatus(id)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: enabledBinding(id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(tr("参与翻译与故障转移", "Use for translation and failover"))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowStatus(_ id: ProviderID) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let enabled = store.translation.settings(for: id).isEnabled
            if let entry = health.entry(for: id) {
                let seconds = max(Int(entry.until.timeIntervalSinceNow.rounded()), 1)
                Text(tr("冷却中 · \(entry.error.reason) · \(seconds) 秒", "Cooling down · \(seconds)s"))
                    .foregroundStyle(.orange)
            } else if store.isAvailable(id) {
                Text(id == .deepl ? "DeepL" : store.translation.model(for: id)).foregroundStyle(.secondary)
            } else if enabled {
                Text(tr("配置不完整", "Incomplete")).foregroundStyle(.orange)
            } else {
                Text(tr("未启用", "Off")).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func enabledBinding(_ id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { store.translation.settings(for: id).isEnabled },
            set: { newValue in store.translation.update(id) { $0.isEnabled = newValue } }
        )
    }

    // MARK: Detail

    private var descriptor: ProviderDescriptor { selected.descriptor }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName).font(.headline)
                    Text(descriptor.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Form {
                if descriptor.requiresAPIKey || selected == .custom {
                    LabeledContent("API Key") {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField("", text: $keyDraft, prompt: Text(selected == .custom ? tr("可选", "Optional") : ""))
                                .labelsHidden()
                                .frame(width: 210)
                                .onChange(of: keyDraft) { _, value in
                                    // Skip the echo from loadDraft() so browsing services never resets their cooldown.
                                    if value.trimmingCharacters(in: .whitespacesAndNewlines) != store.apiKey(for: selected) {
                                        store.setAPIKey(value, for: selected)
                                    }
                                }
                            if let url = descriptor.keyURL, selected != .ollama {
                                Link(tr("获取 API Key…", "Get an API Key…"), destination: url).font(.caption)
                            }
                        }
                    }
                }

                if descriptor.editableBaseURL {
                    LabeledContent(tr("接口地址", "Base URL")) {
                        TextField(
                            "", text: baseURLBinding,
                            prompt: Text(descriptor.defaultBaseURL.isEmpty ? "https://…/v1" : descriptor.defaultBaseURL)
                        )
                        .labelsHidden()
                        .frame(width: 210)
                    }
                } else if !descriptor.defaultBaseURL.isEmpty {
                    LabeledContent(tr("接口地址", "Endpoint")) {
                        Text(descriptor.defaultBaseURL.replacingOccurrences(of: "https://", with: ""))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }

                if descriptor.wire != .deepL { modelRows }

                LabeledContent(tr("默认服务", "Default")) {
                    if selected == store.translation.defaultProvider {
                        Label(tr("当前默认服务", "Current default"), systemImage: "star.fill").foregroundStyle(.secondary)
                    } else {
                        Button(tr("设为默认", "Set as Default")) { store.translation.defaultProvider = selected }
                            .disabled(!store.isAvailable(selected))
                    }
                }

                testRows
            }
            .formStyle(.columns)

            Spacer(minLength: 0)
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var modelRows: some View {
        LabeledContent(tr("模型", "Model")) {
            VStack(alignment: .leading, spacing: 6) {
                if selected == .custom || options.isEmpty {
                    TextField("", text: modelBinding, prompt: Text(tr("模型名称", "Model name")))
                        .labelsHidden()
                        .frame(width: 210)
                } else {
                    Picker("", selection: modelBinding) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                if descriptor.supportsModelDiscovery {
                    Button(tr("读取可用模型", "Load Available Models")) { loadModels() }
                        .disabled(isLoadingModels || (descriptor.requiresAPIKey && keyDraft.isEmpty))
                }
            }
        }
    }

    @ViewBuilder
    private var testRows: some View {
        LabeledContent(tr("验证与测速", "Verify & Speed Test")) {
            VStack(alignment: .leading, spacing: 6) {
                if let result = store.benchmarks[selected] {
                    if result.isSuccessful {
                        Label(
                            tr("首字 \(seconds(result.firstTokenSeconds)) · 总计 \(seconds(result.totalSeconds)) · \(Int(result.charactersPerSecond ?? 0)) 字符/秒",
                               "First token \(seconds(result.firstTokenSeconds)) · total \(seconds(result.totalSeconds)) · \(Int(result.charactersPerSecond ?? 0)) chars/s"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .font(.caption)
                    } else if let error = result.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button(tr("验证并测速", "Verify & Test")) { runBenchmark() }
                        .disabled(isTesting || !store.translation.hasRequiredConfiguration(selected, secrets: store.secrets))
                    if isTesting { ProgressView().controlSize(.small) }
                }
                FormNote(tr("会发送一段短文本并消耗少量额度。", "Sends a short text and uses a little quota."))
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if isLoadingModels { ProgressView().controlSize(.small) }
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(message.isError ? Color.red : Color.green)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 18, alignment: .leading)
    }

    // MARK: Bindings and actions

    private var options: [String] {
        var values = discovered[selected] ?? descriptor.fallbackModels
        let current = store.translation.model(for: selected)
        if !current.isEmpty, !values.contains(current) { values.insert(current, at: 0) }
        return values
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { store.translation.model(for: selected) },
            set: { value in store.translation.update(selected) { $0.model = value } }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { store.translation.settings(for: selected).baseURL },
            set: { value in store.translation.update(selected) { $0.baseURL = value } }
        )
    }

    private func loadDraft() {
        keyDraft = store.apiKey(for: selected)
    }

    private func loadModels() {
        let id = selected
        isLoadingModels = true
        message = (tr("正在读取模型…", "Loading models…"), false)
        let settings = store.translation
        let secrets = store.secrets
        Task {
            do {
                let models = try await ModelDiscovery.fetch(id, settings: settings, secrets: secrets)
                discovered[id] = models
                if let first = models.first, !models.contains(store.translation.model(for: id)) {
                    store.translation.update(id) { $0.model = first }
                }
                message = (tr("已读取 \(models.count) 个可用模型", "Loaded \(models.count) models"), false)
            } catch {
                message = (error.localizedDescription, true)
            }
            isLoadingModels = false
        }
    }

    private func runBenchmark() {
        let id = selected
        isTesting = true
        message = nil
        let settings = store.translation
        let secrets = store.secrets
        Task {
            let result = await ProviderBenchmark.run(id, settings: settings, secrets: secrets)
            store.record(result)
            if result.isSuccessful { health.reset(id) }
            isTesting = false
        }
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2fs", value)
    }
}
