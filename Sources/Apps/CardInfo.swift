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
        self.frame = frame
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

                    let set = [card.setNameEN ?? card.setName, card.number, card.rarity]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !set.isEmpty { Text(set).font(.callout).foregroundStyle(.secondary) }
                    if let a = card.illustrator {
                        Text("Illus. \(a)").font(.caption).foregroundStyle(.secondary)
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
