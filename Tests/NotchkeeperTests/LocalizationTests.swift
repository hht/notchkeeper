import Foundation
import Testing

/// String Catalog 齐不齐（docs/ui.md「多语言」）：每个键都有 English，没有 stale 的键；Info.plist 声明了两种语言。
/// 代码里的文案改了先跑 scripts/strings.sh 同步，再补译文
@Suite struct LocalizationCoverage {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable { var state: String; var value: String }
                struct Variant: Decodable { var stringUnit: Unit }
                /// 带数字的句子分单复数（「Up to 1 row」），译文在 variations.plural 里
                struct Variations: Decodable { var plural: [String: Variant]? }
                var stringUnit: Unit?
                var variations: Variations?

                var translated: Bool {
                    if let plural = variations?.plural {
                        return plural["other"] != nil && plural.values.allSatisfy { $0.stringUnit.state == "translated" && !$0.stringUnit.value.isEmpty }
                    }
                    return stringUnit?.state == "translated" && stringUnit?.value.isEmpty == false
                }
            }
            var shouldTranslate: Bool?
            var extractionState: String?
            var localizations: [String: Localization]?
        }
        var sourceLanguage: String
        var strings: [String: Entry]
    }

    private func catalog(_ name: String) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: Self.root.appendingPathComponent("Resources/\(name).xcstrings")))
    }

    @Test(arguments: ["Localizable", "InfoPlist"])
    func everyKeyTranslated(_ name: String) throws {
        let c = try catalog(name)
        #expect(c.sourceLanguage == "zh-Hans")
        #expect(!c.strings.isEmpty)
        for (key, entry) in c.strings where entry.shouldTranslate != false {
            #expect(entry.localizations?["en"]?.translated == true, "\(name)：「\(key)」没有 English")
        }
    }

    /// 英文要分单复数的：数字会是 1 的
    @Test func pluralsWhereCountVaries() throws {
        let plural = try catalog("Localizable").strings["最多 %lld 行"]?.localizations?["en"]?.variations?.plural
        #expect(plural?["one"]?.stringUnit.value == "Up to %lld row")
    }

    /// stale：代码里已经没有这句了，删掉
    @Test(arguments: ["Localizable", "InfoPlist"])
    func noStaleKeys(_ name: String) throws {
        let stale = try catalog(name).strings.filter { $0.value.extractionState == "stale" }.keys.sorted()
        #expect(stale.isEmpty, "\(name) 里 stale 的键：\(stale)")
    }

    /// 不写 CFBundleAllowMixedLocalizations：实测日文环境下会判成 en 却显示中文（docs/ui.md「多语言」）
    @Test func infoPlistDeclaresLanguages() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Support/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "zh-Hans")
        #expect(plist["CFBundleLocalizations"] as? [String] == ["zh-Hans", "en"])
        #expect(plist["CFBundleAllowMixedLocalizations"] == nil)
    }
}
