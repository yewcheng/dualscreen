import CoreGraphics
import Foundation

/// One window on the external workspace.
///
/// `frame` is normalised to 0...1 against the external display, so a workspace
/// saved on a 1080p monitor restores correctly on a 4K one.
struct WindowModel: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: AppKind
    var title: String
    var frame: CGRect
    var z: Int
    var isMinimised: Bool = false
    /// Frame to restore to when un-maximising; nil means the window is not maximised.
    var restoreFrame: CGRect? = nil

    var isMaximised: Bool { restoreFrame != nil }

    /// Per-window document state. Only the fields an app actually uses are set.
    var text: String = ""
    var bookmark: Data? = nil
    var fileName: String? = nil
    var pageIndex: Int = 0
    /// Pointer position for web windows, normalised inside the window body.
    var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    func pixelFrame(in size: CGSize) -> CGRect {
        CGRect(x: frame.origin.x * size.width,
               y: frame.origin.y * size.height,
               width: frame.size.width * size.width,
               height: frame.size.height * size.height)
    }
}
