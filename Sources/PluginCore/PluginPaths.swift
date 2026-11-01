import Foundation
import GuardCore

/// 收件箱和插件登记的位置：App 和 `pipctl` 共用。照 Maildir：写进 `tmp/`，写完 rename 到 `new/`，App 只读 `new/`，读不到写了一半的文件
/// @see https://cr.yp.to/proto/maildir.html
public enum PluginPaths {
    public static let inbox = GuardPaths.directory.appendingPathComponent("inbox", isDirectory: true)
    public static let tmp = inbox.appendingPathComponent("tmp", isDirectory: true)
    public static let new = inbox.appendingPathComponent("new", isDirectory: true)
    /// `plugins/<id>/manifest.json` 登记一个外部插件
    public static let plugins = GuardPaths.directory.appendingPathComponent("plugins", isDirectory: true)
    /// 升级换下来的、卸掉的插件目录挪到这里，不删
    public static let backup = GuardPaths.directory.appendingPathComponent("backup/plugins", isDirectory: true)
}
