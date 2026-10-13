import SwiftUI

/// Reads the live-show chat out of the auction window, logs who said what, and
/// picks out the comments asking for a card or set, for the crowd panel on the
/// right of the monitor.
@MainActor
final class CrowdChat: ObservableObject {
    struct Comment: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let user: String
        let text: String
        let isRequest: Bool
        var done = false
    }

    static let shared = CrowdChat()

    @Published private(set) var comments: [Comment] = []
    /// Shows the crowd panel on the monitor and starts reading the chat.
    @Published var showPanel = false { didSet { showPanel ? start() : stop() } }
    @Published private(set) var status: String?

    var requests: [Comment] { comments.filter { $0.isRequest && !$0.done } }

    private var seen = Set<String>()
    private var poller: Task<Void, Never>?
    /// Which window to read; the capture panel's auction picker sets it.
    var auction: () -> WindowModel? = { nil }

    private init() {
        #if DEBUG
        _ = Self.selfCheck
        #endif
    }

    func markDone(_ c: Comment) {
        if let i = comments.firstIndex(where: { $0.id == c.id }) { comments[i].done = true }
    }

    private func start() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let a = self.auction(), let rows = await WebViewStore.shared.chatRows(a.id) {
                    self.status = rows.isEmpty ? "no chat found in \(a.title)" : nil
                    self.take(rows)
                } else {
                    self.status = "open the auction window"
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stop() { poller?.cancel(); poller = nil }

    private func take(_ rows: [[String]]) {
        for lines in rows {
            guard let (user, text) = Self.split(lines) else { continue }
            // shortcut: the page gives no message ids, so the same person repeating
            // the same words is logged once; switch to ids if Carousell exposes them.
            guard seen.insert(user + "\u{1}" + text).inserted else { continue }
            let c = Comment(at: Date(), user: user, text: text, isRequest: Self.isRequest(text))
            comments.insert(c, at: 0)
            log(c)
        }
        if comments.count > 500 { comments.removeLast(comments.count - 500) }
    }

    /// A chat row as the page shows it: name on the first line and the message
    /// below, or "name: message" on one line.
    static func split(_ lines: [String]) -> (String, String)? {
        if lines.count >= 2 { return (lines[0], lines.dropFirst().joined(separator: " ")) }
        guard let line = lines.first, let colon = line.firstIndex(of: ":") else { return nil }
        let user = line[..<colon].trimmingCharacters(in: .whitespaces)
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return user.isEmpty || text.isEmpty ? nil : (user, text)
    }

    static func isRequest(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(lf|lfg|looking for|wtb|want|wants|any|anyone have|do you have|got any|have any|show|pls|please|request|set|box|booster|sar|sir|ar|chase)\b|\?"#,
                   options: .regularExpression) != nil
    }

    /// One CSV per show in the app's Documents folder.
    private func log(_ c: Comment) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("chat-\(LiveCapture.showDate()).csv")
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let line = [ISO8601DateFormatter().string(from: c.at), q(c.user), q(c.text), c.isRequest ? "request" : ""]
            .joined(separator: ",") + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? ("time,user,comment,kind\n" + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    #if DEBUG
    static let selfCheck: Void = {
        assert(split(["ash", "lf moonbreon"])! == ("ash", "lf moonbreon"))
        assert(split(["misty: any 151 SARs?"])! == ("misty", "any 151 SARs?"))
        assert(split(["hello"]) == nil)
        assert(isRequest("Any Terastal Festival?"))
        assert(isRequest("LF charizard ex"))
        assert(!isRequest("nice pull"))
    }()
    #endif
}

extension WebViewStore {
    /// The last chat rows on the page, each as its visible lines.
    /// shortcut: guesses the chat list as the chat/comment/message-classed element
    /// with the most children, in the top frame only; pin a real selector once
    /// checked against a live Carousell show.
    @MainActor
    func chatRows(_ id: UUID) async -> [[String]]? {
        let js = """
        let best = null, n = 0;
        document.querySelectorAll('[class*="chat" i],[class*="comment" i],[class*="message" i]').forEach(el => {
          if (el.children.length > n) { best = el; n = el.children.length; }
        });
        if (!best) return '[]';
        return JSON.stringify([...best.children].slice(-60).map(r =>
          r.innerText.split('\\n').map(s => s.trim()).filter(Boolean)));
        """
        guard let raw = try? await callAsyncJavaScript(id, js) as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String]]
    }
}

/// Right-hand column of the monitor while a show is on: the card on show, then
/// what the crowd is asking for, then the latest chat.
struct CrowdPanel: View {
    @ObservedObject private var chat = CrowdChat.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardInfoPanel()

            Label("Requests", systemImage: "hand.raised.fill").font(.title3.weight(.bold))
            if chat.requests.isEmpty {
                Text(chat.status ?? "Nothing asked yet").foregroundStyle(.secondary)
            }
            ForEach(chat.requests.prefix(8)) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.user).font(.headline).foregroundStyle(.yellow)
                    Text(c.text).font(.title3)
                }
            }

            Divider()
            Text("Chat").font(.headline).foregroundStyle(.secondary)
            ForEach(chat.comments.prefix(12)) { c in
                (Text(c.user + "  ").bold() + Text(c.text))
                    .font(.callout).lineLimit(2).foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.45))
        .foregroundStyle(.white)
    }
}

/// Controller side: the switch, and the open requests to tick off.
struct CrowdControls: View {
    @ObservedObject private var chat = CrowdChat.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Crowd panel on monitor", isOn: $chat.showPanel)
            if let s = chat.status { Text(s).font(.caption2).foregroundStyle(.secondary) }
            ForEach(chat.requests) { c in
                Button { chat.markDone(c) } label: {
                    HStack {
                        Image(systemName: "circle")
                        Text(c.user).bold()
                        Text(c.text).lineLimit(2)
                        Spacer()
                    }.font(.callout)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
