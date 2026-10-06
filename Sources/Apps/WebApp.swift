import SwiftUI
import WebKit
import Combine

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

    private override init() {
        super.init()
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }

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

        // Put saved logins back before the first request, or the page loads
        // signed out and the site may overwrite the cookie we were holding.
        if let url = Self.normalised(initialURL) {
            CookieVault.restore { view.load(URLRequest(url: url)) }
        }
        return view
    }

    /// Fires with a window id when its page has probably changed, so the
    /// controller's picture of it can refresh without waiting for the timer.
    let pageChanged = PassthroughSubject<UUID, Never>()

    private func notifySoon(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.pageChanged.send(id)
        }
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
        pageChanged.send(id)
    }

    /// Click whatever sits at a normalised point in the window.
    /// `elementFromPoint` is viewport-relative, so scroll position is handled for us.
    func click(_ id: UUID, at point: CGPoint) {
        guard let view = views[id] else { return }
        let x = point.x * view.bounds.width
        let y = point.y * view.bounds.height
        // Modern sites listen for pointer events rather than mouse events, and
        // a synthetic 'click' event is not always honoured — so send the full
        // pointer/mouse sequence, then call the real click() on the nearest
        // clickable ancestor (a link, button, label or input).
        let js = """
        (function() {
          var el = document.elementFromPoint(\(x), \(y));
          if (!el) { return 'miss'; }
          var opts = { bubbles: true, cancelable: true, composed: true, view: window,
                       clientX: \(x), clientY: \(y), button: 0, buttons: 1,
                       pointerId: 1, pointerType: 'mouse', isPrimary: true };
          el.dispatchEvent(new PointerEvent('pointerover', opts));
          el.dispatchEvent(new PointerEvent('pointerdown', opts));
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          var target = el.closest('a, button, label, input, select, textarea, summary, [role=button], [role=link], [role=tab], [role=option], [role=menuitem], [onclick], [tabindex]') || el;
          if (target.focus) { try { target.focus({ preventScroll: true }); } catch (e) {} }
          opts.buttons = 0;
          el.dispatchEvent(new PointerEvent('pointerup', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          if (typeof target.click === 'function') { target.click(); }
          else { el.dispatchEvent(new MouseEvent('click', opts)); }
          // Did that land in somewhere to type? The controller opens the iPad
          // keyboard for it, starting from what the field already holds.
          var f = document.activeElement;
          var textTypes = ['text', 'search', 'email', 'url', 'tel', 'password', 'number', ''];
          var editable = f && ((f.tagName === 'INPUT' && textTypes.indexOf((f.type || '').toLowerCase()) >= 0)
                               || f.tagName === 'TEXTAREA' || f.isContentEditable);
          return JSON.stringify({ editable: !!editable,
                                  value: editable ? (f.isContentEditable ? f.innerText : f.value) || '' : '',
                                  secret: !!(editable && f.type === 'password') });
        })();
        """
        view.evaluateJavaScript(js) { [weak self] result, _ in
            guard let text = result as? String,
                  let info = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  info["editable"] as? Bool == true else { return }
            self?.fieldTapped.send(FieldTap(window: id,
                                            value: info["value"] as? String ?? "",
                                            secret: info["secret"] as? Bool ?? false))
        }
        notifySoon(id)
    }

    struct FieldTap {
        let window: UUID
        let value: String
        let secret: Bool
    }

    /// Fires when a click lands in a text field, so the controller can raise the keyboard.
    let fieldTapped = PassthroughSubject<FieldTap, Never>()

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
          if (el.isContentEditable) {
            el.innerText = "\(escaped)";
            el.dispatchEvent(new Event('input', { bubbles: true }));
            return 'ok';
          }
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

    /// The page at full size, for reading and recording rather than previewing.
    @MainActor
    func fullSnapshot(_ id: UUID) async -> UIImage? {
        guard let view = views[id], view.bounds.width > 0 else { return nil }
        return await withCheckedContinuation { done in
            view.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) }
        }
    }

    enum PostError: LocalizedError {
        case noWindow, notLoggedIn, server(String)
        var errorDescription: String? {
            switch self {
            case .noWindow:     return "The ClaimDesk window isn't open."
            case .notLoggedIn:  return "Log in to ClaimDesk in its window first."
            case .server(let m): return m
            }
        }
    }

    /// POST a JPEG from inside the page in window `id`, so the request carries
    /// that page's own login cookie. Returns the decoded JSON reply.
    @MainActor
    func postImage(_ id: UUID, path: String, jpeg: Data) async throws -> [String: Any] {
        guard let view = views[id] else { throw PostError.noWindow }
        let js = """
        const bytes = Uint8Array.from(atob(img), c => c.charCodeAt(0));
        const r = await fetch(path, { method: 'POST', credentials: 'same-origin',
                                      headers: { 'Content-Type': 'image/jpeg' }, body: bytes });
        return JSON.stringify({ status: r.status, body: await r.text() });
        """
        let raw = try await view.callAsyncJavaScript(
            js, arguments: ["img": jpeg.base64EncodedString(), "path": path],
            in: nil, contentWorld: .page)
        guard let text = raw as? String,
              let outer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let status = outer["status"] as? Int else {
            throw PostError.server("ClaimDesk sent back something unexpected.")
        }
        let body = (outer["body"] as? String) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        if status == 401 { throw PostError.notLoggedIn }
        guard (200..<300).contains(status) else {
            throw PostError.server((json["detail"] as? String) ?? "ClaimDesk error \(status)")
        }
        return json
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
        CookieVault.save()
    }
}

extension WebViewStore: WKHTTPCookieStoreObserver {
    /// Logins done by a page's own scripts set cookies without a navigation.
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        CookieVault.save()
    }
}

/// Keeps web logins across app restarts.
///
/// WKWebView already stores cookies that have an expiry date, but most sites
/// log you in with a *session* cookie, which WebKit drops when the process
/// ends — every 7-day SideStore refresh or swipe-away meant logging in again.
/// This copies every cookie into the app's own sandbox and puts them back on
/// launch.
enum CookieVault {
    private static var restored = false
    private static var waiting: [() -> Void] = []

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookies.plist")
    }

    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    static func save() {
        // Saving mid-restore would overwrite the file with a partial set.
        guard restored else { return }
        store.getAllCookies { cookies in
            let saved: [[String: Any]] = cookies.compactMap { cookie in
                guard let props = cookie.properties else { return nil }
                // Property-list keys must be strings.
                return Dictionary(uniqueKeysWithValues: props.map { ($0.key.rawValue, $0.value) })
            }
            if let data = try? PropertyListSerialization.data(fromPropertyList: saved,
                                                               format: .binary, options: 0) {
                try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            }
        }
    }

    /// Runs `then` once saved cookies are back in the store (only restores once).
    static func restore(then: @escaping () -> Void) {
        if restored { then(); return }
        waiting.append(then)
        guard waiting.count == 1 else { return }

        let saved = (try? Data(contentsOf: fileURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [[String: Any]] } ?? []
        let cookies = saved.compactMap { dict in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues:
                dict.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }

        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            restored = true
            let pending = waiting
            waiting = []
            pending.forEach { $0() }
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
/// of the real web view, refreshed about three times a second.
private struct WebMirror: View {
    let window: WindowModel
    @State private var shot: UIImage?

    private let refresh = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

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
            .onReceive(WebViewStore.shared.pageChanged.filter { $0 == window.id }
                .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)) { _ in
                grab(geo.size)
            }
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
    @State private var secret = false
    @FocusState private var addressFocused: Bool
    @FocusState private var typingFocused: Bool

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

            // Tapping a text field in the page focuses this box, which raises
            // the iPad keyboard; every keystroke is copied into the page field.
            HStack(spacing: 8) {
                Group {
                    if secret {
                        SecureField("tap a text box in the page to type", text: $typing)
                    } else {
                        TextField("tap a text box in the page to type", text: $typing)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($typingFocused)
                .submitLabel(.go)
                .onSubmit(enter)
                .onChange(of: typing) { text in
                    if typingFocused { WebViewStore.shared.type(window.id, text) }
                }
                Button("Enter", action: enter)
                if typingFocused {
                    Button("Done") { typingFocused = false }
                }
            }
            .buttonStyle(.bordered)
        }
        .onAppear { address = window.text }
        .onChange(of: window.id) { _ in address = ws.focused?.text ?? "" }
        .onReceive(WebViewStore.shared.fieldTapped.receive(on: RunLoop.main)) { tap in
            guard tap.window == window.id else { return }
            typingFocused = false          // set the text before focusing, so it isn't echoed back
            secret = tap.secret
            typing = tap.value
            DispatchQueue.main.async { typingFocused = true }
        }
    }

    private func enter() {
        WebViewStore.shared.type(window.id, typing)
        WebViewStore.shared.submit(window.id)
        typing = ""
        typingFocused = false
    }

    private func go() {
        addressFocused = false
        ws.setURL(window.id, address)
        WebViewStore.shared.load(window.id, address)
    }
}
