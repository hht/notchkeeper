import Testing
import GuardCore
@testable import GuardProbes

@Suite struct NetworkPathSnapshot {
    private func snap(_ satisfied: Bool, _ ifaces: [(String, Bool)], gateway: Bool = true) -> NetworkPath {
        NetworkPathProbe.snapshot(satisfied: satisfied, interfaces: ifaces.map { .init(name: $0.0, isPhysical: $0.1) },
                                  hasGateway: gateway)
    }

    @Test func wifiOrEthernetWithGatewayIsUp() {
        #expect(snap(true, [("en0", true)]) == NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true))
        #expect(snap(true, [("utun1024", false), ("en7", true)]).isUp)
    }

    /// 只有 utun（Clash 的 TUN）满足不算有物理网络：断网时 TUN 网卡还在
    @Test func onlyTunnelIsNotAPhysicalInterface() {
        #expect(!snap(true, [("utun1024", false)]).physicalInterfaceSatisfied)
        // 名字是 utun 的一律不算，即使系统把它报成物理类型
        #expect(!snap(true, [("utun3", true)]).physicalInterfaceSatisfied)
    }

    @Test func unsatisfiedPathIsDown() { #expect(!snap(false, [("en0", true)]).physicalInterfaceSatisfied) }
    @Test func noGatewayIsNoDefaultRoute() { #expect(!snap(true, [("en0", true)], gateway: false).hasDefaultRoute) }
}
