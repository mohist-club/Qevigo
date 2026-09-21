import XCTest
@testable import PoptroCore

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
