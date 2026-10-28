import XCTest
@testable import QevigoCore

final class StreamParsingTests: XCTestCase {
    func testOpenAIContentDoneAndErrors() {
        XCTAssertEqual(StreamLine.openAI(#"data: {"choices":[{"delta":{"content":"你好"}}]}"#), .content("你好"))
        XCTAssertEqual(StreamLine.openAI(#"data:{"choices":[{"delta":{"content":"a"}}]}"#), .content("a"))
        XCTAssertEqual(StreamLine.openAI("data: [DONE]"), .done)
        XCTAssertEqual(StreamLine.openAI(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignore)
        XCTAssertEqual(StreamLine.openAI(": keep-alive"), .ignore)
        XCTAssertEqual(StreamLine.openAI(#"data: {"error":{"message":"boom"}}"#), .failure("boom"))
    }

    func testGeminiParts() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Hel"},{"text":"lo"}]}}]}"#
        XCTAssertEqual(StreamLine.gemini(line), .content("Hello"))
        XCTAssertEqual(StreamLine.gemini(#"data: {"promptFeedback":{"blockReason":"SAFETY"}}"#), .failure("blocked: SAFETY"))
    }

    func testOllamaNDJSON() {
        XCTAssertEqual(StreamLine.ollama(#"{"message":{"content":"hi"},"done":false}"#), .content("hi"))
        XCTAssertEqual(StreamLine.ollama(#"{"message":{"content":""},"done":true}"#), .done)
        XCTAssertEqual(StreamLine.ollama(#"{"error":"model not found"}"#), .failure("model not found"))
    }

    func testHTTPErrorMapping() {
        func failure(_ status: Int) -> TranslationFailure {
            HTTP.error(status: status, body: Data(), response: nil, provider: .groq).failure
        }
        XCTAssertEqual(failure(401), .unauthorized)
        XCTAssertEqual(failure(456), .quotaExceeded)
        XCTAssertEqual(failure(402), .paymentRequired)
        XCTAssertEqual(failure(429), .rateLimited(retryAfter: nil))
        XCTAssertEqual(failure(503), .server(503))
        XCTAssertEqual(failure(404), .badRequest)
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(HTTP.errorMessage(from: Data(#"{"error":{"message":"bad key"}}"#.utf8)), "bad key")
        XCTAssertEqual(HTTP.errorMessage(from: Data(#"{"message":"quota"}"#.utf8)), "quota")
    }
}

final class ThinkFilterTests: XCTestCase {
    private func run(_ chunks: [String]) -> String {
        var filter = ThinkTagFilter()
        return chunks.map { filter.push($0) }.joined() + filter.finish()
    }

    func testPassThroughWithoutTags() {
        XCTAssertEqual(run(["Hello ", "world"]), "Hello world")
    }

    func testRemovesThinkBlock() {
        XCTAssertEqual(run(["<think>plan</think>\n你好"]), "你好")
    }

    func testTagSplitAcrossChunks() {
        XCTAssertEqual(run(["<th", "ink>secret</thi", "nk>OK"]), "OK")
    }

    func testAngleBracketThatIsNotATag() {
        XCTAssertEqual(run(["a < b and <b>bold</b>"]), "a < b and <b>bold</b>")
    }

    func testUnterminatedThinkDropsReasoning() {
        XCTAssertEqual(run(["<think>never closed"]), "")
    }
}

final class SettingsTests: XCTestCase {
    func testEmptyJSONDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(TranslationSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.defaultProvider, .zhipu)
        XCTAssertEqual(settings.primaryLanguageCode, "ZH")
        XCTAssertEqual(settings.model(for: .groq), ProviderCatalog.descriptor(for: .groq).defaultModel)
        XCTAssertEqual(Set(settings.failover.order), Set(ProviderID.allCases))
    }

    func testUnknownProviderInSavedOrderIsDroppedAndNewOnesAppended() throws {
        let json = #"{"failover":{"order":["groq","aliens","zhipu","groq"]}}"#
        let settings = try JSONDecoder().decode(TranslationSettings.self, from: Data(json.utf8))
        XCTAssertEqual(Array(settings.failover.order.prefix(2)), [.groq, .zhipu])
        XCTAssertEqual(Set(settings.failover.order), Set(ProviderID.allCases))
        XCTAssertEqual(settings.failover.order.count, ProviderID.allCases.count)
    }

    func testRoundTripKeepsProviderSettings() throws {
        var settings = TranslationSettings()
        settings.update(.groq) { $0.isEnabled = true; $0.model = "llama-x" }
        settings.update(.custom) { $0.baseURL = "http://localhost:1234/v1" }
        let decoded = try JSONDecoder().decode(TranslationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.model(for: .groq), "llama-x")
        XCTAssertEqual(decoded.baseURL(for: .custom), "http://localhost:1234/v1")
    }

    func testAvailabilityRequiresEnabledAndCredentials() {
        var settings = TranslationSettings()
        let secrets = InMemorySecretStore()
        XCTAssertFalse(settings.isAvailable(.groq, secrets: secrets))

        settings.update(.groq) { $0.isEnabled = true }
        XCTAssertFalse(settings.isAvailable(.groq, secrets: secrets), "enabled but no key")

        secrets.setSecret("  key  ", for: .groq)
        XCTAssertTrue(settings.isAvailable(.groq, secrets: secrets))

        settings.update(.groq) { $0.isEnabled = false }
        XCTAssertFalse(settings.isAvailable(.groq, secrets: secrets), "has key but disabled")
    }

    func testOllamaNeedsNoKeyAndCustomNeedsEndpointAndModel() {
        var settings = TranslationSettings()
        let secrets = InMemorySecretStore()
        settings.update(.ollama) { $0.isEnabled = true }
        XCTAssertTrue(settings.isAvailable(.ollama, secrets: secrets))

        settings.update(.custom) { $0.isEnabled = true }
        XCTAssertFalse(settings.isAvailable(.custom, secrets: secrets))
        settings.update(.custom) { $0.baseURL = "http://localhost:1234/v1"; $0.model = "local-model" }
        XCTAssertTrue(settings.isAvailable(.custom, secrets: secrets))
    }

    func testPreferencesClampTransparency() throws {
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"glassTransparency":5}"#.utf8))
        XCTAssertEqual(prefs.glassTransparency, 0.85)
    }

    func testSecretStoreEncryptsOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedFileSecretStore(store: JSONFileStore(directory: dir))
        store.setSecret("sk-secret-123", for: .openai)
        XCTAssertEqual(store.secret(for: .openai), "sk-secret-123")

        let raw = try String(contentsOf: dir.appendingPathComponent(StoreFile.secrets))
        XCTAssertFalse(raw.contains("sk-secret-123"))

        let reopened = EncryptedFileSecretStore(store: JSONFileStore(directory: dir))
        XCTAssertEqual(reopened.secret(for: .openai), "sk-secret-123")
        reopened.setSecret("", for: .openai)
        XCTAssertNil(reopened.secret(for: .openai))
    }
}

final class LanguageTests: XCTestCase {
    func testDetectionAndDirection() {
        var settings = TranslationSettings()
        settings.primaryLanguageCode = "ZH"
        settings.secondaryLanguageCode = "EN-US"
        XCTAssertEqual(LanguageDetector.detectedCode("这是一个中文句子，用来测试语言识别。"), "ZH")
        XCTAssertEqual(LanguageDetector.defaultTargetCode(for: "这是一个中文句子，用来测试语言识别。", settings: settings), "EN-US")
        XCTAssertEqual(LanguageDetector.defaultTargetCode(for: "This is a plain English sentence.", settings: settings), "ZH")
        XCTAssertEqual(LanguageDetector.defaultTargetCode(for: "", settings: settings), "ZH")
    }

    func testCatalogIsConsistent() {
        XCTAssertEqual(Set(Languages.all.map(\.code)).count, Languages.all.count)
        XCTAssertTrue(Languages.deepLTargets.isSubset(of: Set(Languages.all.map(\.code))))
    }

    func testPromptCarriesEnglishTargetName() {
        let prompt = PromptBuilder.systemPrompt(base: "BASE", targetLanguageCode: "JA")
        XCTAssertTrue(prompt.hasPrefix("BASE"))
        XCTAssertTrue(prompt.contains("Japanese"))
    }
}

final class BindingTests: XCTestCase {
    func testLegacyBindingJSONDecodes() throws {
        let json = """
        [{"id":"0E0E5F40-9C6B-4E5B-9E58-4D9E0F0F0F0F","appName":"Safari","appBundlePath":"/Applications/Safari.app","hotkeyName":"launch_x"}]
        """
        let bindings = try JSONDecoder().decode([LaunchBinding].self, from: Data(json.utf8))
        XCTAssertEqual(bindings.first?.name, "Safari")
        XCTAssertEqual(bindings.first?.kind, .application)
        XCTAssertEqual(bindings.first?.isEnabled, true)
    }

    func testExecutionSpecs() {
        let shell = LaunchBinding(name: "x", payload: "echo hi", kind: .script, scriptKind: .shell)
        XCTAssertEqual(shell.executionSpec, ShortcutExecutionSpec(executable: "/bin/zsh", arguments: ["-lc", "echo hi"]))
        let run = LaunchBinding(name: "Focus", payload: "Focus", kind: .shortcut)
        XCTAssertEqual(run.executionSpec?.arguments, ["run", "Focus"])
        XCTAssertNil(LaunchBinding(name: "Safari", payload: "/Applications/Safari.app", kind: .application).executionSpec)
    }
}

final class LegacyImportTests: XCTestCase {
    func testTranslationSettingsMigration() throws {
        let json = """
        {"provider":"groq","configuredProviders":["groq","openai","apple"],"model":"gpt-4.1","groqModel":"qwen/x",
         "zhipuModel":"glm-4-flash-250414","ollamaBaseURL":"http://10.0.0.5:11434","ollamaModel":"llama3",
         "customSystemPrompt":"MY PROMPT","primaryLanguageCode":"JA","secondaryLanguageCode":"EN-GB"}
        """
        let settings = try XCTUnwrap(LegacyImport.translation(fromLegacyJSON: Data(json.utf8)))
        XCTAssertEqual(settings.defaultProvider, .groq)
        XCTAssertTrue(settings.settings(for: .groq).isEnabled)
        XCTAssertTrue(settings.settings(for: .openai).isEnabled)
        XCTAssertFalse(settings.settings(for: .deepl).isEnabled)
        XCTAssertEqual(settings.model(for: .openai), "gpt-4.1")
        XCTAssertEqual(settings.model(for: .groq), "qwen/x")
        XCTAssertEqual(settings.baseURL(for: .ollama), "http://10.0.0.5:11434")
        XCTAssertEqual(settings.model(for: .ollama), "llama3")
        XCTAssertEqual(settings.systemPrompt, "MY PROMPT")
        XCTAssertEqual(settings.primaryLanguageCode, "JA")
        XCTAssertEqual(settings.secondaryLanguageCode, "EN-GB")
    }

    func testPreferencesMigrationRenamesAppearance() throws {
        let json = #"{"interfaceLanguage":"english","appearanceMode":"dark","glassEffectEnabled":false,"glassTransparency":0.3}"#
        let prefs = try XCTUnwrap(LegacyImport.preferences(fromLegacyJSON: Data(json.utf8)))
        XCTAssertEqual(prefs.interfaceLanguage, .english)
        XCTAssertEqual(prefs.appearance, .dark)
        XCTAssertFalse(prefs.glassEffectEnabled)
        XCTAssertEqual(prefs.glassTransparency, 0.3)
    }

    func testLoadReadsFilesAndPlaintextKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"provider":"zhipu"}"#.utf8).write(to: dir.appendingPathComponent("translation_settings.json"))
        try Data(#"[{"id":"0E0E5F40-9C6B-4E5B-9E58-4D9E0F0F0F0F","appName":"Safari","appBundlePath":"/Applications/Safari.app"}]"#.utf8)
            .write(to: dir.appendingPathComponent("launch_bindings.json"))

        let defaults: [String: Any] = [
            "com.menubartranslator.local.groq-api-key": "plain-key",
            "KeyboardShortcuts_translateSelection": #"{"carbonKeyCode":5,"carbonModifiers":256}"#
        ]
        let snapshot = LegacyImport.load(supportDirectory: dir, defaults: defaults)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.translation?.defaultProvider, .zhipu)
        XCTAssertEqual(snapshot.bindings.count, 1)
        XCTAssertEqual(snapshot.apiKeys[.groq], "plain-key")
        XCTAssertNotNil(snapshot.shortcuts["KeyboardShortcuts_translateSelection"])
    }

    func testEmptyWhenNothingExists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(LegacyImport.load(supportDirectory: dir, defaults: nil).isEmpty)
    }
}

final class SSHConfigTests: XCTestCase {
    func testParsesAliasesWithDetails() {
        let config = """
        # comment
        Host web
            HostName example.com
            User deploy
            Port 2222

        Host db
          HostName=10.0.0.5
        """
        let hosts = SSHConfig.hosts(parsing: config)
        XCTAssertEqual(hosts.map(\.alias), ["web", "db"])
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].detail, "deploy@example.com:2222")
        XCTAssertEqual(hosts[1].hostName, "10.0.0.5")
        XCTAssertEqual(hosts[1].detail, "10.0.0.5")
    }

    func testSkipsPatternsAndDeduplicates() {
        let config = """
        Host *
            AddKeysToAgent yes
        Host !excluded prod
            HostName prod.example.com
        Host prod
            HostName other.example.com
        Host staging?
        """
        let hosts = SSHConfig.hosts(parsing: config)
        XCTAssertEqual(hosts.map(\.alias), ["prod"])
        XCTAssertEqual(hosts[0].hostName, "prod.example.com", "first entry wins, like ssh itself")
    }

    func testOneLineWithSeveralAliases() {
        let hosts = SSHConfig.hosts(parsing: "Host alpha beta\n    User root")
        XCTAssertEqual(hosts.map(\.alias), ["alpha", "beta"])
        XCTAssertTrue(hosts.allSatisfy { $0.user == "root" })
    }

    func testMatchBlockDoesNotLeakIntoPreviousHost() {
        let hosts = SSHConfig.hosts(parsing: "Host web\n  HostName a.com\nMatch host b.com\n  User other")
        XCTAssertEqual(hosts.map(\.alias), ["web"])
        XCTAssertNil(hosts[0].user)
    }

    func testMissingFileIsEmpty() {
        XCTAssertTrue(SSHConfig.hosts(at: URL(fileURLWithPath: "/nonexistent/ssh/config")).isEmpty)
    }
}

final class SSHBindingTests: XCTestCase {
    private func binding(_ alias: String, _ opener: SSHOpener, path: String? = nil) -> LaunchBinding {
        LaunchBinding(name: "server", payload: alias, kind: .ssh, sshOpener: opener, sshRemotePath: path)
    }

    func testTerminalSpecRunsSSHInANewWindow() {
        let spec = binding("web", .terminal).executionSpec
        XCTAssertEqual(spec?.executable, "/usr/bin/osascript")
        XCTAssertEqual(spec?.arguments.first, "-e")
        let script = spec?.arguments.last ?? ""
        XCTAssertTrue(script.contains(#"do script "ssh web""#))
        XCTAssertTrue(script.contains("activate"))
    }

    func testVSCodeSpecUsesRemoteFlagWithAnAbsolutePath() {
        let spec = binding("web", .visualStudioCode, path: "/srv/app").executionSpec
        XCTAssertEqual(spec?.executable, LaunchBinding.vsCodeBinary)
        XCTAssertEqual(spec?.arguments, ["--remote", "ssh-remote+web", "/srv/app"])
    }

    func testVSCodeWithoutAnAbsolutePathWaitsForTheRemoteHome() {
        // VS Code takes the path verbatim, so "~" would be a literal folder name.
        for stored in [nil, "", "~", "~/projects", "projects"] {
            let binding = binding("web", .visualStudioCode, path: stored)
            XCTAssertTrue(binding.needsRemoteHome, "should resolve \(stored ?? "nil") against the server's home")
            XCTAssertNil(binding.executionSpec)
        }
        XCTAssertFalse(binding("web", .visualStudioCode, path: "/srv").needsRemoteHome)
        XCTAssertFalse(binding("web", .terminal).needsRemoteHome)
    }

    func testRemotePathResolution() {
        XCTAssertEqual(LaunchBinding.resolvedRemotePath(nil, home: "/root"), "/root")
        XCTAssertEqual(LaunchBinding.resolvedRemotePath("~", home: "/root"), "/root")
        XCTAssertEqual(LaunchBinding.resolvedRemotePath("~/app", home: "/root"), "/root/app")
        XCTAssertEqual(LaunchBinding.resolvedRemotePath("app", home: "/home/wayne/"), "/home/wayne/app")
        XCTAssertEqual(LaunchBinding.resolvedRemotePath("/srv/app", home: nil), "/srv/app", "absolute paths need no home")
        XCTAssertNil(LaunchBinding.resolvedRemotePath("~/app", home: nil))
    }

    func testDefaultsToTerminalAndRejectsEmptyAlias() {
        XCTAssertEqual(LaunchBinding(name: "s", payload: "web", kind: .ssh).executionSpec?.executable, "/usr/bin/osascript")
        XCTAssertNil(binding("  ", .terminal).executionSpec)
    }

    func testAliasValidationRejectsInjection() {
        XCTAssertTrue(LaunchBinding.isValidHostAlias("web-1.example.com"))
        XCTAssertTrue(LaunchBinding.isValidHostAlias("deploy@10.0.0.5"))
        for bad in [#"web"; rm -rf /"#, "web\nHost other", "web && echo", "-oProxyCommand=x", "web$(id)", "", "web host"] {
            XCTAssertFalse(LaunchBinding.isValidHostAlias(bad), "should reject \(bad)")
        }
    }

    func testSSHBindingSurvivesRoundTrip() throws {
        let original = binding("web", .visualStudioCode, path: "/srv")
        let decoded = try JSONDecoder().decode(LaunchBinding.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testLegacyBindingWithoutSSHFieldsStillDecodes() throws {
        let json = #"{"id":"0E0E5F40-9C6B-4E5B-9E58-4D9E0F0F0F0F","appName":"Safari","appBundlePath":"/Applications/Safari.app"}"#
        let decoded = try JSONDecoder().decode(LaunchBinding.self, from: Data(json.utf8))
        XCTAssertNil(decoded.sshOpener)
        XCTAssertEqual(decoded.kind, .application)
    }
}

final class SSHPublicKeyTests: XCTestCase {
    func testParsesTypeAndComment() throws {
        let key = try XCTUnwrap(SSHPublicKey(path: "/u/.ssh/id_ed25519.pub", contents: "ssh-ed25519 AAAAC3Nz wayne@mac\n"))
        XCTAssertEqual(key.algorithm, "ED25519")
        XCTAssertEqual(key.comment, "wayne@mac")
        XCTAssertEqual(key.fileName, "id_ed25519.pub")
        XCTAssertEqual(key.label, "id_ed25519.pub · wayne@mac", "comment identifies the key; algorithm is noise when present")
        XCTAssertTrue(key.isDefaultIdentity)
    }

    func testCommentMayContainSpacesAndMayBeMissing() throws {
        let withSpaces = try XCTUnwrap(SSHPublicKey(path: "/k.pub", contents: "ssh-rsa AAAAB3 my laptop key"))
        XCTAssertEqual(withSpaces.comment, "my laptop key")
        XCTAssertEqual(withSpaces.algorithm, "RSA")
        let bare = try XCTUnwrap(SSHPublicKey(path: "/k.pub", contents: "ssh-ed25519 AAAAC3Nz"))
        XCTAssertEqual(bare.comment, "")
        XCTAssertEqual(bare.label, "k.pub · ED25519", "falls back to the algorithm when there is no comment")
        XCTAssertFalse(bare.isDefaultIdentity)
    }

    func testAlgorithmNames() {
        XCTAssertEqual(SSHPublicKey.algorithmName("ecdsa-sha2-nistp256"), "ECDSA")
        XCTAssertEqual(SSHPublicKey.algorithmName("ssh-dss"), "DSA")
        XCTAssertTrue(SSHPublicKey.algorithmName("sk-ssh-ed25519@openssh.com").hasPrefix("ED25519"))
        XCTAssertEqual(SSHPublicKey.algorithmName("future-type"), "future-type")
    }

    func testRejectsMalformedFile() {
        XCTAssertNil(SSHPublicKey(path: "/k.pub", contents: ""))
        XCTAssertNil(SSHPublicKey(path: "/k.pub", contents: "ssh-ed25519"))
    }

    func testListsKeysNewestFirstAndSkipsOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "ssh-ed25519 AAAA old@mac".write(to: dir.appendingPathComponent("old.pub"), atomically: true, encoding: .utf8)
        try "private".write(to: dir.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try "ssh-ed25519 AAAA new@mac".write(to: dir.appendingPathComponent("new.pub"), atomically: true, encoding: .utf8)
        // Make the creation order unambiguous regardless of filesystem timestamps.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: dir.appendingPathComponent("old.pub").path)
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: dir.appendingPathComponent("new.pub").path)

        let keys = SSHPublicKey.available(in: dir.path)
        XCTAssertEqual(keys.map(\.fileName), ["new.pub", "old.pub"])

        // ssh's own identity sorts ahead of newer custom keys.
        try "ssh-ed25519 AAAA default@mac".write(to: dir.appendingPathComponent("id_ed25519.pub"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: dir.appendingPathComponent("id_ed25519.pub").path)
        XCTAssertEqual(SSHPublicKey.available(in: dir.path).first?.fileName, "id_ed25519.pub")
    }
}

final class OpenVPNTests: XCTestCase {
    private let binary = "/opt/homebrew/sbin/openvpn"
    private let config = "/Users/wayne/.qevigo/vpn/office.ovpn"

    func testConnectCommandIsFixedAndPinsScriptSecurity() {
        let spec = OpenVPN.connectSpec(binary: binary, config: config, interactive: false)
        XCTAssertEqual(spec.executable, "/usr/bin/sudo")
        XCTAssertEqual(spec.arguments.first, "-n", "non-interactive runs must not block on a password prompt")
        XCTAssertTrue(spec.arguments.contains(binary))
        XCTAssertEqual(spec.arguments.last, "/Users/wayne/.qevigo/vpn/office.log")
        // --script-security must come after --config so a tampered config cannot raise it.
        let securityIndex = try! XCTUnwrap(spec.arguments.firstIndex(of: "--script-security"))
        let configIndex = try! XCTUnwrap(spec.arguments.firstIndex(of: "--config"))
        XCTAssertLessThan(configIndex, securityIndex)
        XCTAssertEqual(spec.arguments[securityIndex + 1], "1")

        let interactive = OpenVPN.connectSpec(binary: binary, config: config, interactive: true)
        XCTAssertNotEqual(interactive.arguments.first, "-n", "interactive runs may ask for the password")
    }

    func testDisconnectUsesThePidFile() {
        let spec = OpenVPN.disconnectSpec(config: config, interactive: false)
        XCTAssertEqual(spec.arguments, ["-n", "/usr/bin/pkill", "-TERM", "-F", "/Users/wayne/.qevigo/vpn/office.pid"])
    }

    func testSudoersRulesMatchTheLaunchCommandExactly() {
        let file = OpenVPN.sudoersFile(user: "wayne", binary: binary, configs: [config])
        let launch = OpenVPN.connectArguments(binary: binary, config: config).joined(separator: " ")
        XCTAssertTrue(file.contains("wayne ALL=(root) NOPASSWD: " + launch), "rule must match what Qevigo runs")
        XCTAssertTrue(file.contains("/usr/bin/pkill -TERM -F /Users/wayne/.qevigo/vpn/office.pid"))
        XCTAssertTrue(file.hasSuffix("\n"))
    }

    func testSudoersEscapesSpecialCharacters() {
        XCTAssertEqual(OpenVPN.escapeForSudoers("/a/Application Support/x"), "/a/Application\\ Support/x")
        XCTAssertEqual(OpenVPN.escapeForSudoers("a:b,c=d#e"), "a\\:b\\,c\\=d\\#e")
        XCTAssertEqual(OpenVPN.escapeForSudoers("/plain/path"), "/plain/path")
    }

    func testConnectionStateFollowsThePidFile() {
        XCTAssertTrue(OpenVPN.isConnected(config: config, readPID: { _ in "4242\n" }, isRunning: { $0 == 4242 }))
        XCTAssertFalse(OpenVPN.isConnected(config: config, readPID: { _ in "4242" }, isRunning: { _ in false }), "stale pid file")
        XCTAssertFalse(OpenVPN.isConnected(config: config, readPID: { _ in nil }, isRunning: { _ in true }), "no pid file")
        XCTAssertFalse(OpenVPN.isConnected(config: config, readPID: { _ in "not a pid" }, isRunning: { _ in true }))
    }

    func testConfigNameValidation() {
        XCTAssertTrue(OpenVPN.isValidConfigName("office-vpn_2"))
        for bad in ["", " ", ".hidden", "with space", "a/b", "a;b", "名称", String(repeating: "x", count: 61)] {
            XCTAssertFalse(OpenVPN.isValidConfigName(bad), "should reject \(bad)")
        }
    }

    func testBinaryLookupPrefersHomebrew() {
        XCTAssertEqual(OpenVPN.installedBinary(checking: { $0 == "/usr/local/sbin/openvpn" }), "/usr/local/sbin/openvpn")
        XCTAssertNil(OpenVPN.installedBinary(checking: { _ in false }))
    }

    func testDerivedPaths() {
        XCTAssertEqual(OpenVPN.pidPath(forConfig: config), "/Users/wayne/.qevigo/vpn/office.pid")
        XCTAssertEqual(OpenVPN.logPath(forConfig: config), "/Users/wayne/.qevigo/vpn/office.log")
        XCTAssertTrue(OpenVPN.configPath(name: "office").hasSuffix("/.qevigo/vpn/office.ovpn"))
    }
}

final class OpenVPNDiagnosticsTests: XCTestCase {
    func testRootOwnedProcessCountsAsRunning() {
        // kill(pid, 0) answers EPERM for a live root process; only ESRCH means gone.
        XCTAssertTrue(OpenVPN.processExists(1), "launchd is always running and owned by root")
        XCTAssertFalse(OpenVPN.processExists(Int32.max - 1), "no such process")
    }

    func testIsConnectedUsesTheSameRule() {
        let config = "/Users/wayne/.qevigo/vpn/office.ovpn"
        XCTAssertTrue(OpenVPN.isConnected(config: config, readPID: { _ in "1" }), "root-owned openvpn is connected")
    }

    func testFailureSummaryPicksTheMeaningfulLines() {
        let log = """
        2026-10-28 17:07:01 OpenVPN 2.7.8 aarch64-apple-darwin27.0.0
        2026-10-28 17:07:01 library versions: OpenSSL 4.1.0
        2026-10-28 17:07:02 RESOLVE: Cannot resolve host address: vpn.example.com
        2026-10-28 17:07:02 Exiting due to fatal error
        """
        let summary = OpenVPN.failureSummary(log: log)
        XCTAssertTrue(summary.contains("Cannot resolve host address"))
        XCTAssertTrue(summary.contains("fatal error"))
        XCTAssertFalse(summary.contains("library versions"), "noise is left out")
        XCTAssertFalse(summary.contains("2026-10-28"), "timestamps are stripped")
    }

    func testFailureSummaryFallsBackToTheLastLines() {
        let log = (1...10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(OpenVPN.failureSummary(log: log, limit: 2), "line 9\nline 10")
    }

    func testReadyMarkerIsTheOpenVPNSuccessLine() {
        XCTAssertEqual(OpenVPN.readyMarker, "Initialization Sequence Completed")
    }
}

final class OpenVPNSafetyTests: XCTestCase {
    private let config = "/Users/wayne/.qevigo/vpn/SG-VPN.ovpn"

    func testProcessLookupMatchesTheConfigPath() {
        let spec = OpenVPN.findProcessesSpec(config: config)
        XCTAssertEqual(spec.executable, "/usr/bin/pgrep")
        XCTAssertEqual(spec.arguments, ["-f", "--", config], "-- stops a path being read as options")
    }

    func testForceDisconnectMatchesTheConfigPath() {
        let spec = OpenVPN.forceDisconnectSpec(config: config, interactive: false)
        XCTAssertEqual(spec.arguments, ["-n", "/usr/bin/pkill", "-TERM", "-f", "--", config])
    }

    func testSudoersAllowsBothWaysToStop() {
        let file = OpenVPN.sudoersFile(user: "wayne", binary: "/opt/homebrew/sbin/openvpn", configs: [config])
        XCTAssertTrue(file.contains("/usr/bin/pkill -TERM -F /Users/wayne/.qevigo/vpn/SG-VPN.pid"),
                      "normal stop, by pid file")
        XCTAssertTrue(file.contains("/usr/bin/pkill -TERM -f -- /Users/wayne/.qevigo/vpn/SG-VPN.ovpn"),
                      "fallback stop, when the pid file is gone")
    }

    func testEveryRuleStaysExactWithNoWildcards() {
        let file = OpenVPN.sudoersFile(user: "wayne", binary: "/opt/homebrew/sbin/openvpn", configs: [config])
        for line in file.split(whereSeparator: \.isNewline) where line.contains("NOPASSWD") {
            XCTAssertFalse(line.contains("*"), "a wildcard would widen what runs as root: \(line)")
            XCTAssertFalse(line.contains("ALL\n"), "no blanket command permission")
        }
    }
}

final class OpenVPNInstallTests: XCTestCase {
    func testPreferredBinaryWinsOverTheUsualLocations() {
        let custom = "/opt/local/sbin/openvpn"
        XCTAssertEqual(OpenVPN.installedBinary(preferred: custom, checking: { _ in true }), custom)
        XCTAssertEqual(
            OpenVPN.installedBinary(preferred: "/gone", checking: { $0 == "/opt/homebrew/sbin/openvpn" }),
            "/opt/homebrew/sbin/openvpn",
            "a preferred path that no longer exists falls back"
        )
        XCTAssertEqual(OpenVPN.installedBinary(preferred: "  ", checking: { $0 == OpenVPN.binaryCandidates[0] }), OpenVPN.binaryCandidates[0])
    }

    func testMacPortsIsSearchedToo() {
        XCTAssertEqual(OpenVPN.installedBinary(checking: { $0 == "/opt/local/sbin/openvpn" }), "/opt/local/sbin/openvpn")
    }

    func testInstallCommandWithAndWithoutHomebrew() {
        XCTAssertEqual(OpenVPN.installCommand(brew: "/opt/homebrew/bin/brew"), "/opt/homebrew/bin/brew install openvpn")
        let bootstrapped = OpenVPN.installCommand(brew: nil)
        XCTAssertTrue(bootstrapped.contains("install.sh"), "Homebrew has to be installed first")
        XCTAssertTrue(bootstrapped.hasSuffix("install openvpn"))
    }

    func testBrewLookup() {
        XCTAssertEqual(OpenVPN.installedBrew(checking: { $0 == "/usr/local/bin/brew" }), "/usr/local/bin/brew")
        XCTAssertNil(OpenVPN.installedBrew(checking: { _ in false }))
    }

    func testVersionOutputRecognition() {
        XCTAssertTrue(OpenVPN.isOpenVPNVersionOutput("OpenVPN 2.7.8 aarch64-apple-darwin27.0.0"))
        XCTAssertFalse(OpenVPN.isOpenVPNVersionOutput("Python 3.13.0"))
        XCTAssertFalse(OpenVPN.isOpenVPNVersionOutput(""))
    }

    func testCustomPathSurvivesSaving() throws {
        var preferences = AppPreferences()
        preferences.openvpnPath = "/opt/local/sbin/openvpn"
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.openvpnPath, "/opt/local/sbin/openvpn")
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8)).openvpnPath, "")
    }
}

final class OpenVPNRuleFreshnessTests: XCTestCase {
    private let binary = "/opt/homebrew/sbin/openvpn"
    private let office = "/Users/wayne/.qevigo/vpn/office.ovpn"
    private let home = "/Users/wayne/.qevigo/vpn/home.ovpn"

    func testRulesCoverExactlyTheConfigsTheyWereWrittenFor() {
        let marker = OpenVPN.rulesMarker(binary: binary, configs: [office])
        XCTAssertTrue(OpenVPN.rulesCover(binary: binary, configs: [office], marker: marker))
        // Renaming a config, which is what silently broke passwordless connects.
        XCTAssertFalse(OpenVPN.rulesCover(binary: binary, configs: [home], marker: marker))
        // Adding a second VPN also needs new rules.
        XCTAssertFalse(OpenVPN.rulesCover(binary: binary, configs: [office, home], marker: marker))
        // So does moving to a different openvpn build.
        XCTAssertFalse(OpenVPN.rulesCover(binary: "/opt/local/sbin/openvpn", configs: [office], marker: marker))
    }

    func testMarkerIgnoresOrdering() {
        XCTAssertEqual(
            OpenVPN.rulesMarker(binary: binary, configs: [office, home]),
            OpenVPN.rulesMarker(binary: binary, configs: [home, office])
        )
    }

    func testMissingMarkerMeansNotCovered() {
        XCTAssertFalse(OpenVPN.rulesCover(binary: binary, configs: [office], marker: nil))
        XCTAssertFalse(OpenVPN.rulesCover(binary: binary, configs: [], marker: "anything"))
    }

    func testInstallCommandWritesTheMarkerAndRemovalClearsIt() {
        let command = OpenVPN.installSudoersCommand(stagedFile: "/tmp/staged", marker: "/tmp/marker")
        XCTAssertTrue(command.contains("visudo -cf /tmp/staged"), "rules are validated before install")
        XCTAssertTrue(command.contains("cp /tmp/marker \(OpenVPN.rulesMarkerPath)"))
        XCTAssertTrue(OpenVPN.removeSudoersCommand().contains("rm -f \(OpenVPN.rulesMarkerPath)"))
    }
}

final class OpenVPNBundledBinaryTests: XCTestCase {
    func testTunnelblickBinariesAreOfferedNewestFirst() {
        let found = OpenVPN.bundledBinaries(listing: { _ in ["openvpn-2.5.8", "openvpn-2.6.12", "README", "openvpn-2.6.9"] })
        XCTAssertEqual(found.first, "/Applications/Tunnelblick.app/Contents/Resources/openvpn/openvpn-2.6.12/openvpn")
        XCTAssertEqual(found.count, 3, "only version directories count")
    }

    func testAnInstalledBinaryWinsOverABundledOne() {
        let bundled = { ["/Applications/Tunnelblick.app/Contents/Resources/openvpn/openvpn-2.6.12/openvpn"] }
        XCTAssertEqual(
            OpenVPN.installedBinary(checking: { $0 == "/opt/homebrew/sbin/openvpn" }, bundled: bundled),
            "/opt/homebrew/sbin/openvpn"
        )
    }

    func testBundledBinaryIsUsedWhenNothingElseIsInstalled() {
        let path = "/Applications/Tunnelblick.app/Contents/Resources/openvpn/openvpn-2.6.12/openvpn"
        XCTAssertEqual(OpenVPN.installedBinary(checking: { $0 == path }, bundled: { [path] }), path)
        XCTAssertNil(OpenVPN.installedBinary(checking: { _ in false }, bundled: { [] }))
    }
}

final class OpenVPNEngineTests: XCTestCase {
    func testTheDownloadableEngineIsPinned() {
        let engine = OpenVPN.downloadableEngine
        XCTAssertTrue(OpenVPN.isEngineDownloadable, "a release without a real digest must not be offered")
        XCTAssertEqual(engine.sha256.count, 64, "a SHA-256 digest in hex")
        XCTAssertTrue(engine.sha256.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(engine.url.scheme, "https", "the engine runs as root; plain http would be a downgrade")
        XCTAssertTrue(engine.url.absoluteString.contains(engine.version), "the URL names the version it serves")
    }

    func testTheManagedEngineIsFoundWhenNothingElseIs() {
        XCTAssertEqual(
            OpenVPN.installedBinary(checking: { $0 == OpenVPN.managedBinaryPath }, bundled: { [] }),
            OpenVPN.managedBinaryPath
        )
        // Something installed by the user still wins, so a brew upgrade keeps working.
        XCTAssertEqual(
            OpenVPN.installedBinary(checking: { $0 == "/opt/homebrew/sbin/openvpn" || $0 == OpenVPN.managedBinaryPath }, bundled: { [] }),
            "/opt/homebrew/sbin/openvpn"
        )
    }

    func testManagedEngineLivesBesideTheConfigurations() {
        XCTAssertTrue(OpenVPN.managedBinaryPath.hasSuffix("/.qevigo/bin/openvpn"))
        XCTAssertFalse(OpenVPN.managedBinaryPath.contains(" "), "sudoers rules cannot express a path with spaces")
    }
}
