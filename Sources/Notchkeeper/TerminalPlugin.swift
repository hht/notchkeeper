import Foundation
import PluginCore

/// 回答：Notchkeeper 自带的终端插件装没装、怎么装、怎么卸。
/// 只拷文件：zsh 脚本和登记拷进 `plugins/terminal/`，脚本调 App 装好的 `bin/pipctl`（`CommandLineTool`）。`plugins/terminal/` 归 App：每次启动整个换成新版，放进去的别的文件会没。
/// 不改 `~/.zshrc`、不读 shell 配置（CLAUDE.md 硬规则）：`source` 那一行由用户自己加
enum TerminalPlugin {
    static let directory = PluginPaths.plugins.appendingPathComponent("terminal", isDirectory: true)
    private static let script = directory.appendingPathComponent("notchkeeper.zsh")

    /// 用户加进 `~/.zshrc` 的一行：用 `$HOME`，换台机器、换个用户名也对；卸载后忘了删这行，新开的 shell 也不报错
    static var sourceLine: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = script.path.hasPrefix(home + "/") ? "$HOME" + script.path.dropFirst(home.count) : script.path
        return "[[ -r \"\(path)\" ]] && source \"\(path)\""
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: script.path) }

    static func install() throws {
        // `swift run` 直接跑时 App 包里没有
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("plugins/terminal", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.path)
        else { throw Failure(errorDescription: String(localized: "这个构建不含终端插件，要用 scripts/run.sh 打包")) }
        try FileManager.default.replaceItem(at: directory, withCopyOf: bundled)
        Log.write("终端插件：已安装")
    }

    static func uninstall() throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // 已经卸掉了
        }
        Log.write("终端插件：已卸载")
    }

    /// App 启动时：装着的话换成 App 里带的这一版，新开的终端就用上
    static func refreshIfInstalled() {
        guard isInstalled else { return }
        do {
            try install()
        } catch {
            Log.write("终端插件：更新失败：\(error.localizedDescription)")
        }
    }
}
