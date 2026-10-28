import SwiftUI

/// 吉祥物的情绪状态。原创角色美术稍后接入，这里只放占位实现。
enum MascotMood: Equatable {
    case idle      // 平静：出口正常 / 无事发生
    case worried   // 担心：出口异常
    case happy     // 开心：任务完成 / 出口恢复
    case unknown   // 迷惑：检测中或无法获取
}

/// 吉祥物插槽：任何原创角色只需实现这个协议，就能放进刘海卡片和面板头部。
protocol MascotRenderable: View {
    init(mood: MascotMood, size: CGFloat)
}

/// 当前使用的吉祥物实现。以后换成原创角色时只改这一行。
typealias Mascot = PlaceholderMascot

/// 占位吉祥物：圆形“小盾”+ SF Symbol 表情，按情绪换色与动效。不使用任何品牌角色或素材。
struct PlaceholderMascot: MascotRenderable {
    let mood: MascotMood
    let size: CGFloat
    @State private var breathe = false

    init(mood: MascotMood, size: CGFloat) {
        self.mood = mood
        self.size = size
    }

    private var tint: Color {
        switch mood {
        case .idle, .happy: return .green
        case .worried: return .red
        case .unknown: return .gray
        }
    }
    private var face: String {
        switch mood {
        case .idle: return "face.smiling"
        case .happy: return "face.smiling.inverse"
        case .worried: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark"
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1)
            Image(systemName: face)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: mood == .worried)
                .symbolEffect(.bounce, value: mood == .happy)
        }
        .frame(width: size, height: size)
        .scaleEffect(breathe ? 1.04 : 0.97)
        .rotationEffect(.degrees(mood == .worried ? (breathe ? -4 : 4) : 0))
        .animation(.easeInOut(duration: mood == .worried ? 0.35 : 1.6).repeatForever(autoreverses: true), value: breathe)
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: mood)
        .onAppear { breathe = true }
        .accessibilityLabel("吉祥物占位")
    }
}

extension GuardStatus {
    var mood: MascotMood {
        switch self {
        case .healthy: return .idle
        case .unhealthy: return .worried
        case .unknown: return .unknown
        }
    }
}
