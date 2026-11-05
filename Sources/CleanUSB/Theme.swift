import SwiftUI

/// 앱 전체에서 쓰는 색·간격. 청록(teal)과 파랑을 강조색으로 사용한다.
enum Theme {
    static let accent = Color(red: 0.00, green: 0.55, blue: 0.62)
    static let accentDeep = Color(red: 0.05, green: 0.36, blue: 0.62)
    static let gradient = LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardCorner: CGFloat = 12

    static func color(for level: StatusMessage.Level) -> Color {
        switch level {
        case .info: return accent
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    static func symbol(for level: StatusMessage.Level) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func color(for outcome: OperationSummary.Outcome) -> Color {
        switch outcome {
        case .success: return .green
        case .partial: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return f
    }()
}

/// 흰 배경 카드. 상세 화면의 각 구역을 감싼다.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// 사용량 막대. 사이드바와 상세 헤더에서 같은 모양으로 쓴다.
struct CapacityBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Theme.gradient)
                    .frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}
