import SwiftUI
import UniformTypeIdentifiers

/// The iPad's screen: launcher, live preview, window list, trackpad and the
/// per-app input panel. Everything the workspace does originates here.
struct ControllerView: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    DisplayBanner()
                    Launcher()
                    WorkspacePreview()
                    SnapBar()
                    Trackpad().frame(height: 96)
                    WindowList()
                    InputPanel()
                }
                .padding(18)
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

/// A live miniature of the external display, rendered from the same views.
/// Tapping a window focuses it.
private struct WorkspacePreview: View {
    @EnvironmentObject private var ws: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(ws.isExternalAttached ? "Monitor" : "Monitor (preview)")
            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: geo.size.width / ws.canvasAspect)
                ZStack(alignment: .topLeading) {
                    WorkspaceView()
                        .environmentObject(ws)
                        .frame(width: 1280, height: 1280 / ws.canvasAspect)
                        .scaleEffect(size.width / 1280, anchor: .topLeading)
                        // scaleEffect does not change the layout size, so pin the
                        // oversized box to the top-left instead of letting it centre.
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                        .environment(\.isMirrorPreview, ws.isExternalAttached)
                        .allowsHitTesting(false)

                    // Hit layer: topmost window under the tap gets focus.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1, coordinateSpace: .local) { point in
                            let n = CGPoint(x: point.x / size.width, y: point.y / size.height)
                            if let hit = ws.windows
                                .filter({ !$0.isMinimised && $0.frame.contains(n) })
                                .max(by: { $0.z < $1.z }) {
                                ws.focus(hit.id)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary))
            }
            .aspectRatio(ws.canvasAspect, contentMode: .fit)
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
