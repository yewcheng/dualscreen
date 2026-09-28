import SwiftUI

/// The applications that can live in a DualScreen window.
///
/// Deliberately absent: a web browser. Third-party iPadOS apps must use
/// WKWebView, which does not render reliably into a non-interactive external
/// scene and cannot be driven without real hit-testing on that screen.
enum AppKind: String, Codable, CaseIterable, Identifiable {
    case notes
    case calculator
    case pdf
    case files
    case dashboard
    case clock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .calculator: return "Calculator"
        case .pdf: return "PDF"
        case .files: return "Files"
        case .dashboard: return "Dashboard"
        case .clock: return "Clock"
        }
    }

    var symbol: String {
        switch self {
        case .notes: return "note.text"
        case .calculator: return "function"
        case .pdf: return "doc.richtext"
        case .files: return "folder"
        case .dashboard: return "square.grid.2x2"
        case .clock: return "clock"
        }
    }

    var accent: Color {
        switch self {
        case .notes: return Color(red: 0.98, green: 0.76, blue: 0.29)
        case .calculator: return Color(red: 0.42, green: 0.71, blue: 0.98)
        case .pdf: return Color(red: 0.95, green: 0.45, blue: 0.42)
        case .files: return Color(red: 0.58, green: 0.80, blue: 0.55)
        case .dashboard: return Color(red: 0.72, green: 0.62, blue: 0.95)
        case .clock: return Color(red: 0.60, green: 0.85, blue: 0.86)
        }
    }

    /// Default window size, as a fraction of the external display.
    var defaultSize: CGSize {
        switch self {
        case .notes: return CGSize(width: 0.38, height: 0.52)
        case .calculator: return CGSize(width: 0.22, height: 0.46)
        case .pdf: return CGSize(width: 0.46, height: 0.70)
        case .files: return CGSize(width: 0.34, height: 0.50)
        case .dashboard: return CGSize(width: 0.40, height: 0.34)
        case .clock: return CGSize(width: 0.24, height: 0.22)
        }
    }

    /// Whether the controller offers a text-entry surface for this app.
    var acceptsTextInput: Bool { self == .notes }
}
