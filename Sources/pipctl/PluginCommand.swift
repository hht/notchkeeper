import AppKit
import Darwin
import Foundation
import NotchCore
import PluginCore
import PluginStore

/// 回答：`pipctl plugin install|uninstall|list` 做什么。装、卸、读登记都归 `PluginStore`，这里只读参数、打印结果。
/// 装上、卸掉后 App 下次收到消息或打开设置页时重读登记，不用重启
enum PluginCommand {
    static let usage = """
        用法：pipctl plugin install <插件文件夹>   校验 manifest.json，拷进插件目录；同 id 的旧版挪进备份
              pipctl plugin uninstall <id>         挪进备份（\(PluginPaths.backup.path)）
              pipctl plugin list                   已装的外部插件：id、名字、图标
        """

    static func run(_ args: [String]) -> Never {
        let store = PluginStore()
        do {
            switch (args.first, args.count) {
            case ("install"?, 2):
                let source = URL(fileURLWithPath: args[1])
                let result = try store.install(source, symbolExists: symbolExists, now: Date())
                print("已安装 \(result.manifest.name)（\(result.manifest.id)）：\(store.plugins.appendingPathComponent(result.manifest.id).path)")
                if let old = result.replaced { print("旧版挪到了 \(old.path)") }
            case ("uninstall"?, 2):
                print("已卸载 \(args[1])，目录挪到了 \(try store.uninstall(args[1], now: Date()).path)")
            case ("list"?, 1):
                let manifests = store.manifests { dir, error in
                    FileHandle.standardError.write(Data("pipctl：\(dir ?? store.plugins.path) 读不了或解不开（\(error)），算没登记\n".utf8))
                }
                for m in manifests.values.sorted(by: { $0.id < $1.id }) {
                    print("\(m.id)\t\(m.name)\t\(m.symbol)\(symbolExists(m.symbol) ? "" : "（系统里没有这个图标）")")
                }
            default:
                PipCtl.fail(usage, status: EX_USAGE)
            }
        } catch let problem as PluginStore.Problem {
            PipCtl.fail("pipctl：\(describe(problem))", status: EX_DATAERR)
        } catch {
            PipCtl.fail("pipctl：\(error.localizedDescription)", status: EX_CANTCREAT)
        }
        exit(0)
    }

    private static func symbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// 和设置页的说法一致（`PluginManagement.swift` 里 `Problem.errorDescription`，那边走 String Catalog）；改一边，两边一起改
    private static func describe(_ problem: PluginStore.Problem) -> String {
        switch problem {
        case .noManifest: return "文件夹里没有 manifest.json"
        case .manifest(.malformed): return "manifest.json 不是 JSON，或缺 id、name、symbol"
        case .manifest(.badID): return "id 只能用小写字母、数字和连字符，至多 32 个字符"
        case .manifest(.reservedID): return "id 是内置插件的（guard、claude），换一个"
        case .manifest(.missingField): return "名字（name）和图标（symbol）不能是空的"
        case .manifest(.tooLong): return "名字至多 \(Card.maxValue) 个字，图标名至多 \(Manifest.maxSymbol) 个字符"
        case .unknownSymbol(let s): return "系统里没有叫 \(s) 的 SF Symbol（名字可以在「SF Symbols」App 里查）"
        case .bundled: return "terminal 是自带的终端插件，在设置 › 终端里装卸"
        case .alreadyInstalled: return "这个文件夹就是已经装着的那份"
        case .notInstalled: return "没装这个插件（pipctl plugin list 看装了哪些）"
        case .exists: return "同 id 的插件已经装着"
        }
    }
}
