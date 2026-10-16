import XCTest
@testable import SpeedCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageUsesFirstSupportedPreference() {
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: ["en-US", "zh-Hans-CN"]), "en")
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: ["zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: ["zh_TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: ["ja-JP", "zh-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.system.resolvedCode(preferredLanguages: []), "en")
    }

    func testExplicitLanguageOverridesSystem() {
        XCTAssertEqual(AppLocalizer(language: .english, preferredLanguages: ["zh-CN"]).languageCode, "en")
        XCTAssertEqual(AppLocalizer(language: .simplifiedChinese, preferredLanguages: ["en-US"]).languageCode, "zh-Hans")
    }

    func testBothCatalogsAreCompleteAndFormatsMatch() throws {
        let english = try catalog("en")
        let chinese = try catalog("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertGreaterThan(english.count, 150)
        let placeholders = try NSRegularExpression(pattern: "%@|%\\.[0-9]+f|%%")
        for (key, value) in english {
            func formats(_ text: String) -> [String] {
                placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    .map { (text as NSString).substring(with: $0.range) }
            }
            XCTAssertEqual(formats(key), formats(value), key)
            XCTAssertFalse(value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }, key)
        }
        // Catch UI keys that were added to code but omitted from both catalogs.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        let calls = try NSRegularExpression(pattern: #"L10n\.text\(("(?:\\.|[^"\\])*")"#)
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url)
            for match in calls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = (source as NSString).substring(with: match.range(at: 1))
                let data = Data(("[" + literal + "]").utf8)
                let key = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String])?.first)
                XCTAssertNotNil(english[key], "Missing translation: \(key)")
            }
        }
    }

    func testEnglishAndChineseFormatting() {
        let english = AppLocalizer(language: .english)
        let chinese = AppLocalizer(language: .simplifiedChinese)
        XCTAssertEqual(english.text("当前 %@ tok/s", "123.4"), "Now 123.4 tok/s")
        XCTAssertEqual(chinese.text("当前 %@ tok/s", "123.4"), "当前 123.4 tok/s")
        XCTAssertEqual(english.text("%@小时%@分", "2", "3"), "2h 3m")
        XCTAssertEqual(chinese.text("%@小时%@分", "2", "3"), "2小时3分")
        XCTAssertEqual(english.text("累计输出 %@ tok · 输入 %@ tok", "10k", "100k"), "Output 10k tok · Input 100k tok")
        XCTAssertEqual(String(format: english.text("推理占输出 %.1f%%"), 50.0), "Reasoning: 50.0% of output")
        XCTAssertEqual(english.text("missing key"), "missing key")
    }

    func testUserTitlesAndExplicitAgentNamesAreNotTranslated() throws {
        let log = SessionLog(url: URL(fileURLWithPath: "/tmp/localization-title.jsonl"))
        log.label = "刷新" // Also a translated UI key; this is still the user's title.
        XCTAssertEqual(SessionSnapshot(log: log).displayLabel, "刷新")
        let record: [String: Any] = ["type": "session_meta", "payload": [
            "id": "child", "agent_nickname": "审核助手", "parent_thread_id": "root",
            "source": ["subagent": ["other": "guardian"]]
        ]]
        var data = try JSONSerialization.data(withJSONObject: record); data.append(10)
        log.ingest(data)
        let agent = AgentSnapshot(log: log)
        XCTAssertFalse(agent.labelIsFallback)
        XCTAssertEqual(agent.displayLabel, "审核助手")
    }

    func testFallbacksAreLocalizedWithoutChangingRawData() {
        let log = SessionLog(url: URL(fileURLWithPath: "/tmp/localization-untitled.jsonl"))
        let session = SessionSnapshot(log: log)
        XCTAssertEqual(session.label, "未命名会话")
        XCTAssertTrue(session.labelIsFallback)
        XCTAssertEqual(session.displayLabel, L10n.text("未命名会话"))
        XCTAssertEqual(session.own.displayLabel, L10n.text("未命名会话"))
        XCTAssertEqual(L10n.modelName(session.model), L10n.text("未知模型"))
        XCTAssertEqual(L10n.modelName("model-example"), "model-example")
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let bundle = AppLocalizer.localizedBundle(for: language)
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
