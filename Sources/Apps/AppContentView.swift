import SwiftUI
import PDFKit
import UIKit

/// Dispatches a window to its app body. Every one of these renders on the
/// external display, so they are all read-only presentations of state the
/// controller owns.
struct AppContentView: View {
    let window: WindowModel
    var scale: CGFloat = 1

    var body: some View {
        switch window.kind {
        case .notes:      NotesBody(text: window.text, scale: scale)
        case .calculator: CalculatorBody(expression: window.text, scale: scale)
        case .pdf:        PDFBody(window: window)
        case .files:      FilesBody(window: window)
        case .dashboard:  DashboardBody(scale: scale)
        case .clock:      ClockBody(scale: scale)
        }
    }
}

// MARK: - Notes

struct NotesBody: View {
    let text: String
    var scale: CGFloat = 1

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Type on the iPad to fill this note." : text)
                .font(.system(size: 15 * scale, design: .default))
                .foregroundStyle(text.isEmpty ? .white.opacity(0.3) : .white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.disabled)
                .padding(16)
        }
    }
}

// MARK: - Calculator

/// Evaluates the controller-entered expression. Shared by both scenes so the
/// iPad and the monitor never disagree about the result.
enum CalcEngine {
    static func evaluate(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        // Reject anything that is not arithmetic before handing it to NSExpression,
        // which will happily evaluate function calls otherwise.
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() %")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let last = cleaned.unicodeScalars.last,
              CharacterSet(charactersIn: "0123456789.)").contains(last) else { return nil }
        let expr = NSExpression(format: cleaned)
        guard let value = expr.expressionValue(with: nil, context: nil) as? NSNumber else { return nil }
        let d = value.doubleValue
        guard d.isFinite else { return nil }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.8g", d)
    }
}

struct CalculatorBody: View {
    let expression: String
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Spacer(minLength: 0)
            Text(expression.isEmpty ? "0" : expression)
                .font(.system(size: 22 * scale, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(CalcEngine.evaluate(expression) ?? " ")
                .font(.system(size: 40 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(18)
    }
}

// MARK: - PDF

struct PDFBody: View {
    let window: WindowModel
    @State private var image: UIImage?
    @State private var pageCount = 0
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                VStack(spacing: 6) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Page \(window.pageIndex + 1) of \(pageCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(10)
            } else {
                Placeholder(symbol: "doc.richtext",
                            message: error ?? (window.bookmark == nil
                                               ? "Choose a PDF from the iPad."
                                               : "Loading…"))
            }
        }
        .task(id: "\(window.bookmark?.count ?? 0)-\(window.pageIndex)") { render() }
    }

    private func render() {
        guard let bookmark = window.bookmark else { image = nil; return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            error = "File is no longer reachable."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else {
            error = "Not a readable PDF."
            return
        }
        pageCount = doc.pageCount
        guard let page = doc.page(at: min(window.pageIndex, max(0, doc.pageCount - 1))) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let target = CGSize(width: 1400, height: 1400 * bounds.height / max(bounds.width, 1))
        image = page.thumbnail(of: target, for: .mediaBox)
        error = nil
    }
}

// MARK: - Files

struct FilesBody: View {
    let window: WindowModel
    @State private var entries: [(name: String, isDir: Bool, size: Int)] = []
    @State private var message: String?

    var body: some View {
        Group {
            if entries.isEmpty {
                Placeholder(symbol: "folder",
                            message: message ?? "Pick a folder from the iPad.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.name) { e in
                            HStack(spacing: 10) {
                                Image(systemName: e.isDir ? "folder.fill" : "doc")
                                    .foregroundStyle(e.isDir ? AppKind.files.accent : .white.opacity(0.5))
                                    .frame(width: 18)
                                Text(e.name).lineLimit(1)
                                Spacer()
                                if !e.isDir {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
            }
        }
        .task(id: window.bookmark?.count ?? 0) { load() }
    }

    private func load() {
        guard let bookmark = window.bookmark else { entries = []; return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            message = "Folder is no longer reachable."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            message = "Could not read that folder."
            return
        }
        entries = items.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return (item.lastPathComponent, values?.isDirectory ?? false, values?.fileSize ?? 0)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
        message = entries.isEmpty ? "Folder is empty." : nil
    }
}

// MARK: - Dashboard

struct DashboardBody: View {
    var scale: CGFloat = 1
    @EnvironmentObject private var ws: Workspace
    @State private var battery: Float = -1

    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            row("Device", UIDevice.current.model)
            row("System", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            row("Display", displayText)
            row("Storage free", storageText)
            row("Battery", battery < 0 ? "—" : "\(Int(battery * 100))%")
        }
        .font(.system(size: 13 * scale))
        .padding(18)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = UIDevice.current.batteryLevel
        }
        .onReceive(tick) { _ in battery = UIDevice.current.batteryLevel }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(.white.opacity(0.9))
        }
    }

    private var displayText: String {
        guard let size = ws.externalSize else { return "iPad only" }
        return "\(Int(size.width * ws.externalScale)) × \(Int(size.height * ws.externalScale)) px"
    }

    private var storageText: String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = v.volumeAvailableCapacityForImportantUsage else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Clock

struct ClockBody: View {
    var scale: CGFloat = 1
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            Text(now, format: .dateTime.hour().minute().second())
                .font(.system(size: 34 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 13 * scale))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .onReceive(tick) { now = $0 }
    }
}

// MARK: - Shared

struct Placeholder: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
            Text(message).font(.system(size: 13)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.35))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
