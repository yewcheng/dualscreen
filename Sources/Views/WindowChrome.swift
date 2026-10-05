import SwiftUI

/// Shared so the controller can tell a title-bar touch from a page touch.
enum WindowChromeMetrics {
    /// Title bar plus the hairline under it.
    static let titleHeight: CGFloat = 31
}

/// Title bar + body for one window. The traffic-light dots are indicators, not
/// buttons: nothing on the external display can be tapped.
struct WindowChrome<Content: View>: View {
    let window: WindowModel
    let isFocused: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(window.kind.accent).frame(width: 9, height: 9)
                Image(systemName: window.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(window.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isFocused ? 0.95 : 0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if window.isMaximised {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: WindowChromeMetrics.titleHeight - 1)
            .background(Color.white.opacity(isFocused ? 0.13 : 0.07))

            Divider().overlay(Color.white.opacity(0.08))

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.09))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? window.kind.accent.opacity(0.75) : Color.white.opacity(0.12),
                              lineWidth: isFocused ? 1.6 : 1)
        )
        .shadow(color: .black.opacity(isFocused ? 0.55 : 0.3),
                radius: isFocused ? 26 : 12, x: 0, y: isFocused ? 14 : 6)
    }
}
