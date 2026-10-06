import SwiftUI

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

                    if !card.links.isEmpty {
                        HStack(spacing: 6) {
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
