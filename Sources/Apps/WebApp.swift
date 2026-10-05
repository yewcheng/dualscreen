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
    private var cursorViews: [UUID: UIView] = [:]

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
        cursorViews.removeValue(forKey: id)?.removeFromSuperview()
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

    /// Move the pointer drawn over the page on the monitor.
    ///
    /// This is a plain UIView pinned above the web content rather than SwiftUI
    /// state: pointer moves arrive continuously from a finger or a mouse, and
    /// republishing the workspace for each one would re-render the whole
    /// controller, miniature and all.
    func moveCursor(_ id: UUID, to point: CGPoint) {
        guard let view = views[id] else { return }
        let cursor = cursorViews[id] ?? makeCursor(in: view, id: id)
        cursor.center = CGPoint(x: point.x * view.bounds.width,
                                y: point.y * view.bounds.height)
        view.bringSubviewToFront(cursor)
    }

    /// Briefly swell the pointer so a click is visible from across the room.
    func flashCursor(_ id: UUID) {
        guard let cursor = cursorViews[id] else { return }
        UIView.animate(withDuration: 0.12, animations: {
            cursor.transform = CGAffineTransform(scaleX: 1.7, y: 1.7)
        }, completion: { _ in
            UIView.animate(withDuration: 0.18) { cursor.transform = .identity }
        })
    }

    private func makeCursor(in view: WKWebView, id: UUID) -> UIView {
        let size: CGFloat = 34
        let halo = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        halo.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        halo.layer.cornerRadius = size / 2
        halo.isUserInteractionEnabled = false
        halo.layer.shadowColor = UIColor.black.cgColor
        halo.layer.shadowOpacity = 0.7
        halo.layer.shadowRadius = 4
        halo.layer.shadowOffset = .zero

        let ring = UIView(frame: CGRect(x: (size - 16) / 2, y: (size - 16) / 2, width: 16, height: 16))
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 2.5
        ring.layer.cornerRadius = 8
        ring.isUserInteractionEnabled = false
        halo.addSubview(ring)

        let dot = UIView(frame: CGRect(x: (size - 5) / 2, y: (size - 5) / 2, width: 5, height: 5))
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 2.5
        dot.isUserInteractionEnabled = false
        halo.addSubview(dot)

        view.addSubview(halo)
        cursorViews[id] = halo
        return halo
    }

    /// A picture of the page, so the controller can show what is being pointed at.
    func snapshot(_ id: UUID, into size: CGSize, completion: @escaping (UIImage?) -> Void) {
        guard let view = views[id], view.bounds.width > 0 else { completion(nil); return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(size.width))
        view.takeSnapshot(with: config) { image, _ in completion(image) }
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
            WebMirror(window: window)
        } else {
            WebViewHost(id: window.id, initialURL: window.text)
                .background(Color.white)
        }
    }
}

/// The miniature's stand-in for a page that is live on the monitor: a snapshot
/// of the real web view, refreshed about once a second.
private struct WebMirror: View {
    let window: WindowModel
    @State private var shot: UIImage?

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Group {
                if let shot {
                    Image(uiImage: shot)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 26, weight: .light))
                        Text(window.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { grab(geo.size) }
            .onReceive(refresh) { _ in grab(geo.size) }
        }
    }

    private func grab(_ size: CGSize) {
        WebViewStore.shared.snapshot(window.id, into: size) { image in
            if let image { shot = image }
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

            WebPad(window: window)
                .frame(height: 300)

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

/// Absolute pointing surface. What you see in it is the page; where you touch is
/// where the cursor goes; the same cursor is drawn on the monitor.
///
/// One finger moves the pointer, a tap clicks, two fingers scroll, and a mouse or
/// trackpad drives the pointer by hover with its wheel scrolling — iPadOS delivers
/// those as indirect events, which is why this is UIKit and not a SwiftUI gesture.
final class PointerPadView: UIView {
    var onCursor: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onScroll: ((CGSize) -> Void)?

    private var lastScroll: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove))
        move.maximumNumberOfTouches = 1
        addGestureRecognizer(move)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        twoFinger.minimumNumberOfTouches = 2
        addGestureRecognizer(twoFinger)

        // Mouse wheel and trackpad scrolling arrive as indirect events, never as
        // touches, so this recogniser accepts no touch types at all.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        addGestureRecognizer(wheel)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func normalised(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / max(bounds.width, 1), 0), 1),
                y: min(max(point.y / max(bounds.height, 1), 0), 1))
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = normalised(g.location(in: self))
        onCursor?(p)
        onClick?(p)
    }

    @objc private func handleMove(_ g: UIPanGestureRecognizer) {
        onCursor?(normalised(g.location(in: self)))
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: onCursor?(normalised(g.location(in: self)))
        default: break
        }
    }

    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastScroll = .zero
        case .changed:
            let t = g.translation(in: self)
            let dx = t.x - lastScroll.x
            let dy = t.y - lastScroll.y
            lastScroll = t
            // Dragging up pushes the page up, as on a touchscreen.
            onScroll?(CGSize(width: -dx / max(bounds.width, 1),
                             height: -dy / max(bounds.height, 1)))
        default:
            lastScroll = .zero
        }
    }
}

struct PointerPad: UIViewRepresentable {
    var onCursor: (CGPoint) -> Void
    var onClick: (CGPoint) -> Void
    var onScroll: (CGSize) -> Void

    func makeUIView(context: Context) -> PointerPadView {
        let view = PointerPadView()
        view.onCursor = onCursor
        view.onClick = onClick
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ view: PointerPadView, context: Context) {
        view.onCursor = onCursor
        view.onClick = onClick
        view.onScroll = onScroll
    }
}

/// The pad, the page picture behind it, and the cursor on top.
struct WebPad: View {
    @EnvironmentObject private var ws: Workspace
    let window: WindowModel

    @State private var shot: UIImage?
    @State private var cursor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var flash = false

    private let refresh = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                if let shot {
                    Image(uiImage: shot)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text("waiting for the page").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Crosshair(flash: flash)
                    .position(x: cursor.x * geo.size.width, y: cursor.y * geo.size.height)
                    .allowsHitTesting(false)

                PointerPad(
                    onCursor: { p in
                        cursor = p
                        WebViewStore.shared.moveCursor(window.id, to: p)
                    },
                    onClick: { p in
                        WebViewStore.shared.click(window.id, at: p)
                        WebViewStore.shared.flashCursor(window.id)
                        ws.setCursor(window.id, p)
                        flash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { flash = false }
                        // The page has probably changed; refresh sooner than the timer.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { grab(geo.size) }
                    },
                    onScroll: { delta in
                        WebViewStore.shared.scroll(window.id, byFractionOfViewport: delta)
                        grab(geo.size)
                    })
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
            .onAppear {
                cursor = window.cursor
                WebViewStore.shared.moveCursor(window.id, to: window.cursor)
                grab(geo.size)
            }
            .onReceive(refresh) { _ in grab(geo.size) }
        }
    }

    private func grab(_ size: CGSize) {
        WebViewStore.shared.snapshot(window.id, into: size) { image in
            if let image { shot = image }
        }
    }
}

private struct Crosshair: View {
    let flash: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(flash ? 0.45 : 0.18))
                .frame(width: flash ? 30 : 20, height: flash ? 30 : 20)
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Circle().fill(Color.accentColor))
                .frame(width: 11, height: 11)
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
        .animation(.easeOut(duration: 0.15), value: flash)
    }
}
