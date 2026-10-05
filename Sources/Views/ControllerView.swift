import SwiftUI
import UniformTypeIdentifiers

/// The iPad's screen: launcher, live preview, window list, trackpad and the
/// per-app input panel. Everything the workspace does originates here.
struct ControllerView: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        NavigationStack {
            // The preview is the main way to arrange windows, so it never sits
            // inside the ScrollView — a scroll view would eat the drags.
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    HStack(alignment: .top, spacing: 18) {
                        WorkspacePreview()
                            .frame(width: geo.size.width * 0.70)
                        controls
                    }
                    .padding(18)
                } else {
                    VStack(spacing: 14) {
                        WorkspacePreview()
                        controls
                    }
                    .padding(18)
                }
            }
            .navigationTitle("DualScreen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { ws.tileAll() } label: { Label("Tile all windows", systemImage: "square.grid.2x2") }
                        Button { ws.cycleFocus() } label: { Label("Cycle focus", systemImage: "arrow.triangle.2.circlepath") }
                        Toggle(isOn: Binding(get: { ws.keepAlive },
                                             set: { ws.keepAlive = $0 })) {
                            Label("Hold display in background", systemImage: "bolt.horizontal")
                        }
                        Picker("Wallpaper", selection: Binding(get: { ws.wallpaper },
                                                               set: { ws.wallpaper = $0; ws.save() })) {
                            Text("Midnight").tag(0)
                            Text("Plum").tag(1)
                            Text("Pine").tag(2)
                            Text("Mono").tag(3)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 18) {
                DisplayBanner()
                Launcher()
                SnapBar()
                WindowList()
                InputPanel()
            }
        }
    }
}

// MARK: - Banner

private struct DisplayBanner: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ws.isExternalAttached ? "display.2" : "display.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(ws.isExternalAttached ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.isExternalAttached ? "External display connected" : "No external display")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detail: String {
        if let s = ws.externalSize {
            return "\(Int(s.width * ws.externalScale)) × \(Int(s.height * ws.externalScale)) px · workspace is live"
        }
        return "Connect USB-C to HDMI. The preview below shows what will appear."
    }
}

// MARK: - Launcher

private struct Launcher: View {
    @EnvironmentObject private var ws: Workspace

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    /// The two sites get their own tiles so they open straight onto the right
    /// page instead of a generic web window someone has to type an address into.
    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let kind: AppKind
        var url: String? = nil
    }

    private var items: [Item] {
        [Item(title: "Croissant", symbol: "crown", kind: .web,
              url: "https://timetocook.tail947b31.ts.net/"),
         Item(title: "Carousell", symbol: "cart", kind: .web,
              url: "https://www.carousell.sg/")]
        + AppKind.allCases.filter { $0 != .web }.map {
            Item(title: $0.title, symbol: $0.symbol, kind: $0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Open")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    Button {
                        ws.open(item.kind, url: item.url,
                                title: item.url == nil ? nil : item.title)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.symbol).font(.title3)
                            Text(item.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(item.kind.accent.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Preview

/// A live miniature of the external display, rendered from the same views, and
/// the one surface everything is done on: drag a title bar to move, drag the
/// bottom-right corner to resize, double-tap a title bar to maximise, and tap or
/// drag inside a web page to click or scroll it.
private struct WorkspacePreview: View {
    @EnvironmentObject private var ws: Workspace

    private enum DragMode { case move, resize, scroll }
    @State private var drag: (id: UUID, mode: DragMode)?
    @State private var lastTranslation: CGSize = .zero

    /// The preview renders WorkspaceView at this width and scales it down.
    private static let canvasWidth: CGFloat = 1280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: geo.size.width / ws.canvasAspect)
                let canvas = CGSize(width: Self.canvasWidth, height: Self.canvasWidth / ws.canvasAspect)
                let s = size.width / canvas.width
                let layout = Layout(
                    area: CGSize(width: size.width,
                                 height: WorkspaceView.windowArea(in: canvas).height * s),
                    titleHeight: WindowChromeMetrics.titleHeight * s)

                ZStack(alignment: .topLeading) {
                    WorkspaceView()
                        .environmentObject(ws)
                        .frame(width: canvas.width, height: canvas.height)
                        .scaleEffect(s, anchor: .topLeading)
                        // scaleEffect does not change the layout size, so pin the
                        // oversized box to the top-left instead of letting it centre.
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .environment(\.isMirrorPreview, ws.isExternalAttached)
                        .allowsHitTesting(false)

                    // Resize grips on the visible windows' bottom-right corners.
                    ForEach(ws.windows.filter { !$0.isMinimised }) { w in
                        let f = layout.frame(of: w)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .opacity(w.id == ws.focusedID ? 1 : 0.5)
                            .position(x: f.maxX - 11, y: f.maxY - 11)
                            .allowsHitTesting(false)
                    }

                    // Hit layer: one surface takes every gesture and works out
                    // which window, and which part of it, is under the finger.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { e in
                                    guard let hit = layout.hit(e.location, in: ws.windows) else { return }
                                    if hit.window.kind == .web, let p = hit.body {
                                        click(hit.window.id, at: p)
                                    } else {
                                        ws.toggleMaximise(hit.window.id)
                                    }
                                }
                                .exclusively(before: SpatialTapGesture(count: 1)
                                    .onEnded { e in
                                        guard let hit = layout.hit(e.location, in: ws.windows) else { return }
                                        ws.focus(hit.window.id)
                                        if hit.window.kind == .web, let p = hit.body {
                                            click(hit.window.id, at: p)
                                        }
                                    })
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in dragChanged(value, layout) }
                                .onEnded { _ in drag = nil }
                        )
                        .frame(width: size.width, height: size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary))
            }
            .aspectRatio(ws.canvasAspect, contentMode: .fit)

            Text("drag title bar to move · drag ↘ to resize · double-tap title to maximise · tap or drag a page to click or scroll")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func dragChanged(_ value: DragGesture.Value, _ layout: Layout) {
        if drag == nil {
            guard let hit = layout.hit(value.startLocation, in: ws.windows) else { return }
            let f = layout.frame(of: hit.window)
            let grip: CGFloat = 36
            let mode: DragMode
            if value.startLocation.x > f.maxX - grip && value.startLocation.y > f.maxY - grip {
                mode = .resize
            } else if hit.window.kind == .web && hit.body != nil {
                mode = .scroll
            } else {
                mode = .move
            }
            drag = (hit.window.id, mode)
            lastTranslation = .zero
            ws.focus(hit.window.id)
        }
        guard let current = drag else { return }
        let dx = value.translation.width - lastTranslation.width
        let dy = value.translation.height - lastTranslation.height
        lastTranslation = value.translation
        let normalised = CGSize(width: dx / layout.area.width, height: dy / layout.area.height)
        switch current.mode {
        case .move:
            ws.move(current.id, by: normalised)
        case .resize:
            ws.resize(current.id, by: normalised)
        case .scroll:
            guard let w = ws.windows.first(where: { $0.id == current.id }) else { return }
            let body = layout.body(of: w)
            // Dragging up pushes the page up, as on a touchscreen.
            WebViewStore.shared.scroll(current.id, byFractionOfViewport:
                CGSize(width: -dx / max(body.width, 1), height: -dy / max(body.height, 1)))
        }
    }

    private func click(_ id: UUID, at p: CGPoint) {
        ws.setCursor(id, p)
        WebViewStore.shared.moveCursor(id, to: p)
        WebViewStore.shared.click(id, at: p)
        WebViewStore.shared.flashCursor(id)
    }

    /// Where windows sit inside the preview, in preview points.
    private struct Layout {
        let area: CGSize
        let titleHeight: CGFloat

        func frame(of w: WindowModel) -> CGRect { w.pixelFrame(in: area) }

        func body(of w: WindowModel) -> CGRect {
            let f = frame(of: w)
            return CGRect(x: f.minX, y: f.minY + titleHeight,
                          width: f.width, height: max(f.height - titleHeight, 1))
        }

        /// Topmost window under `point`, plus the point normalised to its body
        /// (nil when the point is on the title bar).
        func hit(_ point: CGPoint, in windows: [WindowModel]) -> (window: WindowModel, body: CGPoint?)? {
            guard let w = windows
                .filter({ !$0.isMinimised && frame(of: $0).contains(point) })
                .max(by: { $0.z < $1.z }) else { return nil }
            let b = body(of: w)
            guard b.contains(point) else { return (w, nil) }
            return (w, CGPoint(x: (point.x - b.minX) / b.width, y: (point.y - b.minY) / b.height))
        }
    }
}

// MARK: - Snapping

private struct SnapBar: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        HStack(spacing: 8) {
            snap("rectangle.lefthalf.filled", .left)
            snap("rectangle.righthalf.filled", .right)
            snap("rectangle.tophalf.filled", .top)
            snap("rectangle.bottomhalf.filled", .bottom)
            snap("rectangle.center.inset.filled", .centre)
            snap("rectangle.fill", .full)
        }
        .disabled(ws.focusedID == nil)
        .opacity(ws.focusedID == nil ? 0.4 : 1)
    }

    private func snap(_ symbol: String, _ target: Workspace.Snap) -> some View {
        Button {
            if let id = ws.focusedID { ws.snap(id, to: target) }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window list

private struct WindowList: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Windows")
            if ws.windows.isEmpty {
                Text("Nothing open yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            ForEach(ws.windows.sorted(by: { $0.z > $1.z })) { w in
                HStack(spacing: 10) {
                    Image(systemName: w.kind.symbol).foregroundStyle(w.kind.accent).frame(width: 20)
                    Text(w.title).lineLimit(1)
                    Spacer()
                    Button {
                        ws.setMinimised(w.id, !w.isMinimised)
                    } label: {
                        Image(systemName: w.isMinimised ? "arrow.up.left.and.arrow.down.right" : "minus")
                    }
                    Button { ws.toggleMaximise(w.id) } label: {
                        Image(systemName: w.isMaximised ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right.square")
                    }
                    Button(role: .destructive) { ws.close(w.id) } label: {
                        Image(systemName: "xmark")
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(w.id == ws.focusedID ? w.kind.accent.opacity(0.18) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { ws.focus(w.id) }
            }
        }
    }
}

// MARK: - Per-app input

private struct InputPanel: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        if let window = ws.focused {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(window.kind.title)
                switch window.kind {
                case .web:        WebControls(window: window)
                case .notes:      NotesInput(id: window.id, text: window.text)
                case .calculator: CalculatorKeypad(id: window.id, expression: window.text)
                case .pdf:        PDFControls(window: window)
                case .files:      FilesControls(window: window)
                case .dashboard, .clock:
                    Text("This window has no input — it just displays.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NotesInput: View {
    @EnvironmentObject private var ws: Workspace
    let id: UUID
    let text: String
    @State private var draft: String = ""

    var body: some View {
        TextEditor(text: $draft)
            .frame(height: 180)
            .padding(6)
            .background(.quaternary.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear { draft = text }
            .onChange(of: id) { _ in draft = ws.focused?.text ?? "" }
            .onChange(of: draft) { new in ws.updateText(id, new) }
    }
}

private struct CalculatorKeypad: View {
    @EnvironmentObject private var ws: Workspace
    let id: UUID
    let expression: String

    private let keys: [[String]] = [
        ["7", "8", "9", "÷"],
        ["4", "5", "6", "×"],
        ["1", "2", "3", "−"],
        ["0", ".", "(", ")"],
        ["C", "⌫", "+", "="]
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(keys, id: \.first) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        Button { tap(key) } label: {
                            Text(key)
                                .font(.title3.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.quaternary.opacity(0.4),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func tap(_ key: String) {
        var expr = expression
        switch key {
        case "C": expr = ""
        case "⌫": if !expr.isEmpty { expr.removeLast() }
        case "=": if let result = CalcEngine.evaluate(expr) { expr = result }
        default: expr += key
        }
        ws.updateText(id, expr)
    }
}

private struct PDFControls: View {
    @EnvironmentObject private var ws: Workspace
    let window: WindowModel
    @State private var picking = false

    var body: some View {
        HStack(spacing: 10) {
            Button { picking = true } label: { Label("Choose PDF", systemImage: "folder") }
                .buttonStyle(.bordered)
            Spacer()
            Button { ws.setPage(window.id, window.pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(window.pageIndex == 0)
            Text("Page \(window.pageIndex + 1)").font(.callout).monospacedDigit()
            Button { ws.setPage(window.id, window.pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
            }
        }
        .buttonStyle(.bordered)
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.pdf]) { url in
                ws.attachFile(window.id, url: url)
                ws.setPage(window.id, 0)
            }
        }
    }
}

private struct FilesControls: View {
    @EnvironmentObject private var ws: Workspace
    let window: WindowModel
    @State private var picking = false

    var body: some View {
        HStack {
            Button { picking = true } label: { Label("Choose folder", systemImage: "folder") }
                .buttonStyle(.bordered)
            if let name = window.fileName {
                Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.folder]) { url in
                ws.attachFile(window.id, url: url)
            }
        }
    }
}

// MARK: - Shared

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
