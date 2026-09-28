import SwiftUI

/// Everything drawn on the HDMI monitor. Output only — no gesture recognisers
/// live here, because this scene never receives events.
struct WorkspaceView: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Wallpaper(index: ws.wallpaper)

                ForEach(ws.windows.filter { !$0.isMinimised }.sorted(by: { $0.z < $1.z })) { window in
                    let frame = window.pixelFrame(in: geo.size)
                    WindowChrome(window: window, isFocused: window.id == ws.focusedID) {
                        // Web windows draw their own pointer as a UIKit layer over
                        // the page — see WebViewStore.moveCursor — so that pointing
                        // does not republish state sixty times a second.
                        AppContentView(window: window, scale: chromeScale(geo.size))
                    }
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .offset(x: frame.minX, y: frame.minY)
                    .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.85), value: frame)
                }

                StatusBar(size: geo.size)
                    .frame(width: geo.size.width)
                    .offset(y: geo.size.height - 34 * chromeScale(geo.size))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    /// The monitor is much wider than the iPad, and SwiftUI points are not the
    /// same physical size on both. Scale chrome off the display width so title
    /// bars stay readable from a desk away.
    private func chromeScale(_ size: CGSize) -> CGFloat {
        max(0.85, min(1.6, size.width / 1180))
    }
}

struct Wallpaper: View {
    let index: Int

    private static let palettes: [[Color]] = [
        [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.12, green: 0.16, blue: 0.28)],
        [Color(red: 0.11, green: 0.08, blue: 0.14), Color(red: 0.26, green: 0.13, blue: 0.22)],
        [Color(red: 0.05, green: 0.12, blue: 0.12), Color(red: 0.08, green: 0.22, blue: 0.21)],
        [Color.black, Color(white: 0.12)]
    ]

    var body: some View {
        LinearGradient(colors: Self.palettes[index % Self.palettes.count],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// Bottom strip: clock, window count, and the minimised dock.
private struct StatusBar: View {
    @EnvironmentObject private var ws: Workspace
    let size: CGSize
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            Text("DualScreen")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))

            ForEach(ws.windows.filter(\.isMinimised)) { w in
                Label(w.title, systemImage: w.kind.symbol)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.10), in: Capsule())
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Text("\(ws.windows.count) window\(ws.windows.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))

            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(.black.opacity(0.35))
        .onReceive(tick) { now = $0 }
    }
}
