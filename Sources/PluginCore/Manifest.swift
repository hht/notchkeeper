import Foundation
import NotchCore

/// 回答：一个外部插件登没登记、卡上标它什么名字和图标。来自 `plugins/<id>/manifest.json`，不读文件
public struct Manifest: Equatable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol 名
    public var symbol: String

    /// 最长的系统图标名四十来个字符
    public static let maxSymbol = 64

    /// 目录名就是插件 id：对不上的不认，免得一个插件冒用另一个的名字。nil：要装的插件，还没装进 `plugins/<id>/`
    public static func parse(_ data: Data, directoryName: String?) throws(ManifestError) -> Manifest {
        struct Wire: Decodable { var id, name, symbol: String }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw .malformed
        }
        guard wire.id == directoryName ?? wire.id, Message.isPluginID(wire.id) else { throw .badID }
        guard !PluginID.builtIn.contains(wire.id) else { throw .reservedID }
        guard !wire.name.allSatisfy(\.isWhitespace), !wire.symbol.isEmpty else { throw .missingField }
        // 只在安装时拦：已经装着的照常收卡，名字由 `Card` 截短，图标名对不上 App 换成拼图块
        guard directoryName != nil || (wire.name.count <= Card.maxValue && wire.symbol.count <= maxSymbol) else { throw .tooLong }
        return Manifest(id: wire.id, name: wire.name, symbol: wire.symbol)
    }
}

/// 登记文件解不开：这个插件算没登记
public enum ManifestError: Error, Equatable, Sendable {
    case malformed
    /// 不合规，或和目录名对不上
    case badID
    /// 是内置插件的 id（`PluginID.builtIn`）
    case reservedID
    case missingField
    /// 安装时：名字超过 `Card.maxValue` 个字，或图标名超过 `Manifest.maxSymbol`
    case tooLong
}
