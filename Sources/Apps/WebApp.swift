import SwiftUI
import WebKit

/// Web windows are the one case where the non-interactive external scene really
/// bites: the page renders on the monitor but receives no touches there. So the
/// WKWebView lives on the monitor and the iPad drives it — the controller's pad
/// maps 1:1 onto the window, taps become synthetic clicks, drags become scrolls.
///
/// A WKWebView is a UIView and can only have one superview, so each window owns
/// exactly one instance here, shared between whichever scene is hosting it.
final class WebViewStore: NSObject {
    static let shared = WebViewStore()

    private var views: [UUID: WKWebView] = [:]

    func webView(for id: UUID, initialURL: String) -> WKWebView {
        if let existing = views[id] { return existing }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = false
        views[id] = view
        idsByView[ObjectIdentifier(view)] = id

        if let url = Self.normalised(initialURL) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func discard(_ id: UUID) {
        if let view = views.removeValue(forKey: id) {
            idsByView.removeValue(forKey: ObjectIdentifier(view))
            view.stopLoading()
            view.removeFromSuperview()
        }
    }

    // MARK: - Commands from the controller

    func load(_ id: UUID, _ raw: String) {
        guard let view = views[id], let url = Self.normalised(raw) else { return }
        view.load(URLRequest(url: url))
    }

    func goBack(_ id: UUID) { views[id]?.goBack() }
    func goForward(_ id: UUID) { views[id]?.goForward() }
    func reload(_ id: UUID) { views[id]?.reload() }

    func canGoBack(_ id: UUID) -> Bool { views[id]?.canGoBack ?? false }
    func canGoForward(_ id: UUID) -> Bool { views[id]?.canGoForward ?? false }

    /// Scroll by a fraction of the viewport. Driving contentOffset directly
    /// works even though the view gets no touches of its own.
    func scroll(_ id: UUID, byFractionOfViewport delta: CGSize) {
        guard let view = views[id] else { return }
        let scrollView = view.scrollView
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let target = CGPoint(
            x: min(max(0, scrollView.contentOffset.x + delta.width * scrollView.bounds.width), maxX),
            y: min(max(0, scrollView.contentOffset.y + delta.height * scrollView.bounds.height), maxY))
        scrollView.setContentOffset(target, animated: false)
    }

    /// Click whatever sits at a normalised point in the window.
    /// `elementFromPoint` is viewport-relative, so scroll position is handled for us.
    func click(_ id: UUID, at point: CGPoint) {
        guard let view = views[id] else { return }
        let x = point.x * view.bounds.width
        let y = point.y * view.bounds.height
        let js = """
        (function() {
          var el = document.elementFromPoint(\(x), \(y));
          if (!el) { return 'miss'; }
          if (el.focus) { try { el.focus(); } catch (e) {} }
          var opts = { bubbles: true, cancelable: true, view: window,
                       clientX: \(x), clientY: \(y) };
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          el.dispatchEvent(new MouseEvent('click', opts));
          return el.tagName;
        })();
        """
        view.evaluateJavaScript(js)
    }

    /// Type into whatever the last click focused.
    func type(_ id: UUID, _ text: String) {
        guard let view = views[id] else { return }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
          var el = document.activeElement;
          if (!el) { return 'none'; }
          var setter = Object.getOwnPropertyDescriptor(el.__proto__, 'value');
          if (setter && setter.set) { setter.set.call(el, "\(escaped)"); }
          else { el.value = "\(escaped)"; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })();
        """
        view.evaluateJavaScript(js)
    }

    /// Press Enter on the focused field — submits most search boxes.
    func submit(_ id: UUID) {
        guard let view = views[id] else { return }
        let js = """
        (function() {
          var el = document.activeElement;
          if (!el) { return 'none'; }
          var opts = { bubbles: true, cancelable: true, key: 'Enter',
                       code: 'Enter', keyCode: 13, which: 13 };
          el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keypress', opts));
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
          if (el.form && el.form.requestSubmit) { el.form.requestSubmit(); }
          return 'ok';
        })();
        """
        view.evaluateJavaScript(js)
    }

    /// Accepts "carousell.sg" as readily as a full URL.
    static func normalised(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    // MARK: - Title/URL reporting

    private var idsByView: [ObjectIdentifier: UUID] = [:]
}

extension WebViewStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = idsByView[ObjectIdentifier(webView)] else { return }
        let title = webView.title?.isEmpty == false
            ? webView.title!
            : (webView.url?.host ?? "Web")
        Workspace.shared.rename(id, to: String(title.prefix(40)))
        if let url = webView.url?.absoluteString {
            Workspace.shared.setURL(id, url)
        }
    }
}

// MARK: - Hosting

/// True while rendering the controller's miniature. A WKWebView cannot be in two
/// hierarchies, so the miniature shows a card instead of stealing the live view.
private struct MirrorPreviewKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var isMirrorPreview: Bool {
        get { self[MirrorPreviewKey.self] }
        set { self[MirrorPreviewKey.self] = newValue }
    }
}

struct WebViewHost: UIViewRepresentable {
    let id: UUID
    let initialURL: String

    func makeUIView(context: Context) -> WKWebView {
        WebViewStore.shared.webView(for: id, initialURL: initialURL)
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct WebBody: View {
    let window: WindowModel
    @Environment(\.isMirrorPreview) private var isMirrorPreview

    var body: some View {
        if isMirrorPreview {
            VStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 26, weight: .light))
                Text(window.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("live on the monitor").font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else {
            WebViewHost(id: window.id, initialURL: window.text)
                .background(Color.white)
        }
    }
}

// MARK: - Controller panel

struct WebControls: View {
    @EnvironmentObject private var ws: Workspace
    let window: WindowModel

    @State private var address: String = ""
    @State private var typing: String = ""
    @FocusState private var addressFocused: Bool

    private static let bookmarks: [(String, String, String)] = [
        ("Croissant TCG", "https://timetocook.tail947b31.ts.net/", "crown"),
        ("Carousell", "https://www.carousell.sg/", "cart")
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { WebViewStore.shared.goBack(window.id) } label: { Image(systemName: "chevron.left") }
                Button { WebViewStore.shared.goForward(window.id) } label: { Image(systemName: "chevron.right") }
                Button { WebViewStore.shared.reload(window.id) } label: { Image(systemName: "arrow.clockwise") }

                TextField("address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($addressFocused)
                    .onSubmit(go)

                Button("Go", action: go).buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                ForEach(Self.bookmarks, id: \.0) { name, url, symbol in
                    Button {
                        address = url
                        go()
                    } label: {
                        Label(name, systemImage: symbol).font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }

            WebPad(id: window.id)
                .frame(height: 210)

            HStack(spacing: 8) {
                TextField("type into the focused field", text: $typing)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Send") {
                    WebViewStore.shared.type(window.id, typing)
                }
                Button("Enter") {
                    WebViewStore.shared.type(window.id, typing)
                    WebViewStore.shared.submit(window.id)
                    typing = ""
                }
            }
            .buttonStyle(.bordered)
        }
        .onAppear { address = window.text }
        .onChange(of: window.id) { _ in address = ws.focused?.text ?? "" }
    }

    private func go() {
        addressFocused = false
        ws.setURL(window.id, address)
        WebViewStore.shared.load(window.id, address)
    }
}

/// Maps 1:1 onto the web window: tap here clicks there, drag scrolls.
private struct WebPad: View {
    let id: UUID
    @State private var last: CGSize = .zero
    @State private var dragged = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12)))
                VStack(spacing: 4) {
                    Image(systemName: "cursorarrow.rays").font(.system(size: 18, weight: .light))
                    Text("tap to click · drag to scroll")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if abs(value.translation.width) + abs(value.translation.height) > 8 {
                            dragged = true
                        }
                        guard dragged else { return }
                        let dx = value.translation.width - last.width
                        let dy = value.translation.height - last.height
                        last = value.translation
                        // Drag up scrolls the page down, as on a touchscreen.
                        WebViewStore.shared.scroll(id, byFractionOfViewport:
                            CGSize(width: -dx / geo.size.width, height: -dy / geo.size.height))
                    }
                    .onEnded { value in
                        if !dragged {
                            let p = CGPoint(x: value.location.x / geo.size.width,
                                            y: value.location.y / geo.size.height)
                            if (0...1).contains(p.x), (0...1).contains(p.y) {
                                WebViewStore.shared.click(id, at: p)
                            }
                        }
                        last = .zero
                        dragged = false
                    }
            )
        }
    }
}
