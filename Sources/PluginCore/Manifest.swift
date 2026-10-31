import Foundation

/// 回答：一个外部插件登没登记、卡上标它什么名字和图标。来自 `plugins/<id>/manifest.json`，不读文件
public struct Manifest: Equatable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol 名
    public var symbol: String

    /// 目录名就是插件 id：对不上的不认，免得一个插件冒用另一个的名字
    public static func parse(_ data: Data, directoryName: String) throws(ManifestError) -> Manifest {
        struct Wire: Decodable { var id, name, symbol: String }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw .malformed
        }
        guard wire.id == directoryName, Message.isPluginID(wire.id) else { throw .badID }
        guard !wire.name.allSatisfy(\.isWhitespace), !wire.symbol.isEmpty else { throw .missingField }
        return Manifest(id: wire.id, name: wire.name, symbol: wire.symbol)
    }
}

/// 登记文件解不开：这个插件算没登记
public enum ManifestError: Error, Equatable, Sendable {
    case malformed
    /// 不合规，或和目录名对不上
    case badID
    case missingField
}
