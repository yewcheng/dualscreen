import SwiftUI

/// The input surface that stands in for a mouse. Drag moves the focused window,
/// pinch resizes it, double-tap maximises. Deltas are converted to normalised
/// workspace units so one finger-inch moves the same fraction of any monitor.
struct Trackpad: View {
    @EnvironmentObject private var ws: Workspace
    /// Pointer speed: >1 means the window travels further than the finger.
    var sensitivity: CGFloat = 1.6

    @State private var lastTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var active = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(active ? 0.13 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )

                VStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 20, weight: .light))
                    Text(ws.focused.map { "Move \($0.title)" } ?? "No window focused")
                        .font(.footnote)
                    Text("drag to move · pinch to resize · double-tap to maximise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let id = ws.focusedID else { return }
                        active = true
                        let dx = value.translation.width - lastTranslation.width
                        let dy = value.translation.height - lastTranslation.height
                        lastTranslation = value.translation
                        ws.move(id, by: CGSize(width: dx / geo.size.width * sensitivity,
                                               height: dy / geo.size.height * sensitivity))
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                        active = false
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard let id = ws.focusedID else { return }
                        let factor = value / lastMagnification
                        lastMagnification = value
                        ws.resize(id, factor: factor)
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
            .onTapGesture(count: 2) {
                if let id = ws.focusedID { ws.toggleMaximise(id) }
            }
        }
    }
}
