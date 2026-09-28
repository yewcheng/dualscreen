import SwiftUI
import Combine

/// Shared state between the iPad controller scene and the external display scene.
///
/// Both scenes live in the same process, so this is a plain ObservableObject —
/// no IPC, no BroadcastChannel, no polling. The controller mutates it; the
/// external scene re-renders.
final class Workspace: ObservableObject {
    static let shared = Workspace()

    @Published private(set) var windows: [WindowModel] = []
    @Published var focusedID: UUID?

    /// Size of the attached display in points, or nil when nothing is attached.
    @Published private(set) var externalSize: CGSize?
    @Published private(set) var externalScale: CGFloat = 1
    @Published var wallpaper: Int = 0

    /// True when a real HDMI/USB-C display is driving a second scene.
    var isExternalAttached: Bool { externalSize != nil }

    /// Aspect ratio the controller should preview with when no display is attached.
    var canvasAspect: CGFloat {
        guard let s = externalSize, s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }

    var focused: WindowModel? {
        guard let id = focusedID else { return nil }
        return windows.first { $0.id == id }
    }

    private var topZ: Int { (windows.map(\.z).max() ?? 0) + 1 }
    private var saveTimer: AnyCancellable?

    private init() {}

    // MARK: - Display lifecycle

    func attachExternalDisplay(size: CGSize, scale: CGFloat) {
        externalSize = size
        externalScale = scale
    }

    func detachExternalDisplay() {
        externalSize = nil
        save()
    }

    // MARK: - Window management

    @discardableResult
    func open(_ kind: AppKind) -> UUID {
        let size = kind.defaultSize
        let origin = cascadeOrigin(for: size)
        var window = WindowModel(kind: kind,
                                 title: kind.title,
                                 frame: CGRect(origin: origin, size: size),
                                 z: topZ)
        if kind == .notes { window.text = "" }
        windows.append(window)
        focusedID = window.id
        scheduleSave()
        return window.id
    }

    func close(_ id: UUID) {
        windows.removeAll { $0.id == id }
        if focusedID == id { focusedID = windows.max(by: { $0.z < $1.z })?.id }
        scheduleSave()
    }

    func focus(_ id: UUID) {
        guard let i = index(of: id) else { return }
        windows[i].z = topZ
        windows[i].isMinimised = false
        focusedID = id
        scheduleSave()
    }

    func setMinimised(_ id: UUID, _ minimised: Bool) {
        guard let i = index(of: id) else { return }
        windows[i].isMinimised = minimised
        if minimised, focusedID == id {
            focusedID = windows.filter { !$0.isMinimised }.max(by: { $0.z < $1.z })?.id
        }
        scheduleSave()
    }

    func toggleMaximise(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if let restore = windows[i].restoreFrame {
            windows[i].frame = restore
            windows[i].restoreFrame = nil
        } else {
            windows[i].restoreFrame = windows[i].frame
            windows[i].frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        focus(id)
    }

    /// Move by a delta expressed in normalised workspace units.
    func move(_ id: UUID, by delta: CGSize) {
        guard let i = index(of: id), !windows[i].isMaximised else { return }
        var f = windows[i].frame
        f.origin.x = clamp(f.origin.x + delta.width, 0, 1 - f.size.width)
        f.origin.y = clamp(f.origin.y + delta.height, 0, 1 - f.size.height)
        windows[i].frame = f
        scheduleSave()
    }

    /// Scale a window about its centre. `factor` is multiplicative.
    func resize(_ id: UUID, factor: CGFloat) {
        guard let i = index(of: id), !windows[i].isMaximised else { return }
        var f = windows[i].frame
        let cx = f.midX, cy = f.midY
        let w = clamp(f.size.width * factor, 0.12, 1)
        let h = clamp(f.size.height * factor, 0.10, 1)
        f.size = CGSize(width: w, height: h)
        f.origin = CGPoint(x: clamp(cx - w / 2, 0, 1 - w), y: clamp(cy - h / 2, 0, 1 - h))
        windows[i].frame = f
        scheduleSave()
    }

    enum Snap { case left, right, top, bottom, full, centre }

    func snap(_ id: UUID, to snap: Snap) {
        guard let i = index(of: id) else { return }
        windows[i].restoreFrame = nil
        switch snap {
        case .left:   windows[i].frame = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right:  windows[i].frame = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top:    windows[i].frame = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: windows[i].frame = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .full:   windows[i].frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .centre: windows[i].frame = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
        }
        focus(id)
    }

    /// Tile every non-minimised window into a grid.
    func tileAll() {
        let visible = windows.filter { !$0.isMinimised }.sorted { $0.z < $1.z }
        guard !visible.isEmpty else { return }
        let cols = Int(ceil(sqrt(Double(visible.count))))
        let rows = Int(ceil(Double(visible.count) / Double(cols)))
        for (n, w) in visible.enumerated() {
            guard let i = index(of: w.id) else { continue }
            let c = n % cols, r = n / cols
            windows[i].restoreFrame = nil
            windows[i].frame = CGRect(x: CGFloat(c) / CGFloat(cols),
                                      y: CGFloat(r) / CGFloat(rows),
                                      width: 1 / CGFloat(cols),
                                      height: 1 / CGFloat(rows))
        }
        scheduleSave()
    }

    /// Bring the bottom-most visible window to the front — repeated use cycles.
    func cycleFocus() {
        let visible = windows.filter { !$0.isMinimised }.sorted { $0.z < $1.z }
        guard let next = visible.first else { return }
        focus(next.id)
    }

    // MARK: - Document state

    func updateText(_ id: UUID, _ text: String) {
        guard let i = index(of: id) else { return }
        windows[i].text = text
        if windows[i].kind == .notes {
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
            windows[i].title = firstLine.isEmpty ? "Notes" : String(firstLine.prefix(28))
        }
        scheduleSave()
    }

    func attachFile(_ id: UUID, url: URL) {
        guard let i = index(of: id) else { return }
        if let data = try? url.bookmarkData(options: .minimalBookmark,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            windows[i].bookmark = data
            windows[i].fileName = url.lastPathComponent
            windows[i].title = url.lastPathComponent
            scheduleSave()
        }
    }

    func setPage(_ id: UUID, _ page: Int) {
        guard let i = index(of: id) else { return }
        windows[i].pageIndex = max(0, page)
        scheduleSave()
    }

    // MARK: - Persistence

    private struct Saved: Codable {
        var windows: [WindowModel]
        var wallpaper: Int
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspace.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        windows = saved.windows
        wallpaper = saved.wallpaper
        focusedID = windows.max(by: { $0.z < $1.z })?.id
    }

    func save() {
        let saved = Saved(windows: windows, wallpaper: wallpaper)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    /// Windows move on every trackpad tick; coalesce writes instead of thrashing disk.
    private func scheduleSave() {
        saveTimer?.cancel()
        saveTimer = Just(())
            .delay(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    // MARK: - Helpers

    private func index(of id: UUID) -> Int? { windows.firstIndex { $0.id == id } }

    private func cascadeOrigin(for size: CGSize) -> CGPoint {
        let n = CGFloat(windows.count % 8)
        return CGPoint(x: min(0.06 + n * 0.04, max(0, 1 - size.width)),
                       y: min(0.08 + n * 0.035, max(0, 1 - size.height)))
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, lo), Swift.max(lo, hi))
    }
}
