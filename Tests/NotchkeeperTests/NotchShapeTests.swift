import SwiftUI
import Testing
@testable import Notchkeeper

/// 卡片边缘的流星沿 `leftHalf` 和它的镜像走，必须和 `path(in:)` 画出来的外形对得上
@Suite struct NotchShapeHalves {
    private let shape = NotchShape(topRadius: 14, bottomRadius: 28, closed: false)
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 90)

    @Test func leftHalfRunsFromTopLeftToBottomCenter() {
        let half = shape.leftHalf(in: rect)
        #expect(half.cgPath.currentPoint == CGPoint(x: rect.midX, y: rect.maxY))
        var first: CGPoint?
        half.forEach { if first == nil, case .move(let p) = $0 { first = p } }
        #expect(first == CGPoint(x: rect.minX, y: rect.minY))
    }

    /// 左半边加上它的镜像，外框和整条外形一样
    @Test func halvesCoverTheOutline() {
        let half = shape.leftHalf(in: rect).cgPath
        var mirror = CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1)
        let both = half.boundingBoxOfPath.union(half.copy(using: &mirror)!.boundingBoxOfPath)
        #expect(both == shape.path(in: rect).cgPath.boundingBoxOfPath)
    }
}
