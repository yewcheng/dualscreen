import SwiftUI
import WebKit

/// Everything ClaimDesk knows about the card on show, from /api/scan/identify-frame.
struct CardInfo: Identifiable {
    struct Price: Identifiable {
        let id = UUID()
        let source: String
        let local: Double
    }
    struct Link: Identifiable {
        let id = UUID()
        let label: String
        let url: String
    }

    let id: String
    /// The card's own name — Japanese for a Japanese card.
    let name: String
    let nameEN: String?
    let typeLine: String?
    let hp: Int?
    let types: [String]
    let evolvesFrom: String?
    let setName: String?
    let setNameEN: String?
    let number: String?
    let rarity: String?
    let illustrator: String?
    let prices: [Price]
    let currency: String
    let links: [Link]
    let imageURL: URL?
    /// Art/mechanic tags from ClaimDesk: "ex", "Full-art supporter", "Trainer Gallery"…
    let tags: [String]
    let setOfficial: Int?
    let setTotal: Int?
    /// Each print of this card (Normal, Holo, Reverse holo…) with its own price.
    let versions: [(label: String, price: Double?)]
    let frame: Data
    let seenAt = Date()

    init?(_ out: [String: Any], frame: Data) {
        let m = out["match"] as? [String: Any] ?? [:]
        let d = out["details"] as? [String: Any] ?? [:]
        func str(_ v: Any?) -> String? {
            guard let s = v as? String, !s.isEmpty else { return nil }
            return s
        }
        guard let id = str(d["id"]) ?? str(m["id"]),
              let name = str(d["name"]) ?? str(m["name"]) else { return nil }
        self.id = id
        self.name = name
        nameEN = str(d["name_en"]) ?? str(m["name_en"])
        typeLine = str(d["type_en"])
        hp = (d["hp"] as? Int) ?? Int(str(d["hp"]) ?? "")
        types = d["types"] as? [String] ?? []
        evolvesFrom = str(d["evolves_from"])
        setName = str(d["set_name"]) ?? str(m["set_name"])
        setNameEN = str(d["set_name_en"])
        number = str(d["number"]) ?? str(m["number"])
        rarity = str(d["rarity_en"]) ?? str(d["rarity_label"])
        illustrator = str(d["illustrator"])
        currency = str(d["currency"]) ?? "SGD"
        prices = (d["prices"] as? [[String: Any]] ?? []).compactMap { p in
            guard let source = p["source"] as? String,
                  let local = (p["local"] as? Double) ?? (p["local"] as? Int).map(Double.init) else { return nil }
            return Price(source: source, local: local)
        }
        links = (d["links"] as? [[String: Any]] ?? []).compactMap { l in
            guard let label = l["label"] as? String, let url = l["url"] as? String else { return nil }
            return Link(label: label, url: url)
        }
        // TCGdex hands out a base address; the picture itself needs a size and format.
        imageURL = str(m["img"]).flatMap { raw -> URL? in
            guard raw.hasPrefix("http") else { return nil }
            let hasExt = ["png", "jpg", "jpeg", "webp"].contains((raw as NSString).pathExtension.lowercased())
            return URL(string: hasExt ? raw : raw + "/high.png")
        }
        tags = d["tags"] as? [String] ?? []
        setOfficial = d["set_official"] as? Int
        setTotal = d["set_total"] as? Int
        versions = (d["variants"] as? [[String: Any]] ?? []).compactMap { v in
            guard let label = v["label"] as? String else { return nil }
            let p = v["price"] as? [String: Any]
            return (label, (p?["local"] as? Double) ?? (p?["local"] as? Int).map(Double.init))
        }
        self.frame = frame
    }

    /// The card's number against the set: secret rares sit past the printed count.
    var isSecret: Bool {
        guard let off = setOfficial, let n = Int((number ?? "").split(separator: "/").first ?? "") else { return false }
        return n > off
    }
}

extension CardInfo {
    /// PriceCharting's search for this card; it lists the graded and ungraded
    /// prices. Opened as a page rather than fetched, because PriceCharting
    /// blocks scripted requests.
    var priceChartingURL: String? {
        let q = [nameEN ?? name, setNameEN ?? setName, number].compactMap { $0 }.joined(separator: " ")
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return "https://www.pricecharting.com/search-products?type=prices&q=" + enc
    }
}

/// The card on show, big enough to read while talking: picture, name, what it
/// is, where it is from, and what it is worth.
struct CardInfoPanel: View {
    @EnvironmentObject private var ws: Workspace
    @ObservedObject private var live = LiveCapture.shared

    var body: some View {
        if let card = live.card {
            HStack(alignment: .top, spacing: 14) {
                picture(card)
                    .frame(width: 120, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(card.name).font(.title2.weight(.bold)).lineLimit(1)
                        if let en = card.nameEN, en != card.name {
                            Text(en).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { live.clearCard() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }

                    let what = [card.typeLine,
                                card.hp.map { "HP \($0)" },
                                card.types.isEmpty ? nil : card.types.joined(separator: "/")]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !what.isEmpty { Text(what).font(.callout) }

                    if let from = card.evolvesFrom {
                        Label("Evolves from \(from)", systemImage: "arrow.turn.down.right")
                            .font(.callout)
                    }

                    // Rarity and art.
                    let art = [card.rarity] + card.tags.map { Optional($0) }
                    let artLine = art.compactMap { $0 }.joined(separator: " · ")
                    if !artLine.isEmpty || card.illustrator != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "paintpalette")
                            Text([artLine.isEmpty ? nil : artLine,
                                  card.illustrator.map { "art by \($0)" }]
                                .compactMap { $0 }.joined(separator: " · "))
                        }
                        .font(.callout)
                    }

                    // Where it sits in the master set.
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                        Text(masterSetLine(card))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if !card.versions.isEmpty {
                        Text("Printed as: " + card.versions.map { v in
                            v.price.map { "\(v.label) \($0.formatted(.currency(code: card.currency)))" } ?? v.label
                        }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    }

                    PriceChartingRow(card: card)

                    if card.prices.isEmpty {
                        Text("No market price listed — check the links")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 14) {
                            ForEach(card.prices.prefix(3)) { p in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.local, format: .currency(code: card.currency))
                                        .font(.headline.monospacedDigit())
                                    Text(p.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }

                    if !card.links.isEmpty || card.priceChartingURL != nil {
                        HStack(spacing: 6) {
                            if let url = card.priceChartingURL {
                                Button("PriceCharting") { ws.open(.web, url: url, title: "PriceCharting") }
                                    .font(.caption)
                                    .buttonStyle(.borderedProminent)
                            }
                            ForEach(card.links) { l in
                                Button(l.label) { ws.open(.web, url: l.url, title: l.label) }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func masterSetLine(_ card: CardInfo) -> String {
        var parts: [String] = [card.setNameEN ?? card.setName ?? "Unknown set"]
        if let n = card.number { parts.append("#\(n)" + (card.isSecret ? " (secret)" : "")) }
        if let total = card.setTotal, let off = card.setOfficial, total > off {
            parts.append("master set \(total) cards (\(off) + \(total - off) secret)")
        } else if let total = card.setTotal ?? card.setOfficial {
            parts.append("master set \(total) cards")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func picture(_ card: CardInfo) -> some View {
        if let url = card.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                frame(card)
            }
        } else {
            frame(card)
        }
    }

    @ViewBuilder
    private func frame(_ card: CardInfo) -> some View {
        if let ui = UIImage(data: card.frame) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.2)
        }
    }
}

/// PriceCharting's prices for the card, read off its own page.
///
/// PriceCharting turns away scripted requests (Cloudflare), so ClaimDesk can't
/// fetch them; a real web view on the iPad gets the page. The search is loaded
/// in an off-screen web view and the price cells are read once they render.
@MainActor
final class PriceChartingLookup: NSObject, ObservableObject {
    struct Prices {
        let title: String?
        let ungraded: String?
        let grade9: String?
        let psa10: String?
    }

    static let shared = PriceChartingLookup()

    @Published private(set) var prices: [String: Prices] = [:]   // by card id
    @Published private(set) var failed: Set<String> = []
    private let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
    private var current: String?

    /// A product page has #used_price etc.; a search page lists products in
    /// #games_table with the same columns (Ungraded, Grade 9, PSA 10).
    private static let read = """
    (() => {
      const t = (root, s) => { const e = root.querySelector(s); return e ? e.textContent.replace(/\\s+/g, ' ').trim() : null; };
      if (document.querySelector('#used_price')) {
        return JSON.stringify({ title: t(document, '#product_name'),
          ungraded: t(document, '#used_price .price'), grade9: t(document, '#graded_price .price'),
          psa10: t(document, '#manual_only_price .price') });
      }
      const row = document.querySelector('#games_table tbody tr');
      if (row) {
        return JSON.stringify({ title: t(row, 'td.title a'), ungraded: t(row, 'td.used_price'),
          grade9: t(row, 'td.cib_price'), psa10: t(row, 'td.new_price') });
      }
      return null;
    })()
    """

    func fetch(_ card: CardInfo) async {
        guard prices[card.id] == nil, !failed.contains(card.id),
              let raw = card.priceChartingURL, let url = URL(string: raw) else { return }
        current = card.id
        web.load(URLRequest(url: url))
        // Cloudflare may show a check page first; give the real page up to 20s.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard current == card.id else { return }          // a newer card took over
            if let json = try? await web.evaluateJavaScript(Self.read) as? String,
               let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                prices[card.id] = Prices(title: d["title"] as? String, ungraded: d["ungraded"] as? String,
                                         grade9: d["grade9"] as? String, psa10: d["psa10"] as? String)
                return
            }
        }
        failed.insert(card.id)
    }
}

/// Ungraded · Grade 9 · PSA 10 from PriceCharting, in its own currency (USD).
private struct PriceChartingRow: View {
    let card: CardInfo
    @ObservedObject private var lookup = PriceChartingLookup.shared

    var body: some View {
        Group {
            if let p = lookup.prices[card.id] {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 14) {
                        cell(p.ungraded, "Ungraded")
                        cell(p.grade9, "Grade 9")
                        cell(p.psa10, "PSA 10")
                    }
                    if let title = p.title {
                        Text("PriceCharting · \(title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if lookup.failed.contains(card.id) {
                Text("PriceCharting: no match found").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("PriceCharting…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: card.id) { await lookup.fetch(card) }
    }

    private func cell(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value ?? "–").font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
