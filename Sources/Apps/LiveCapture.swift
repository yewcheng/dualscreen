import SwiftUI
import Vision
import WebKit

/// Records auction lots into ClaimDesk while a Carousell Live show runs, as a
/// backup for the lots the export or Show Summary later fails to record.
///
/// Capture takes a picture of the auction window, reads the lot number off it
/// with on-device text recognition, and posts the picture to ClaimDesk, which
/// files it under today's show and names the card with its own card index.
/// The upload runs inside the ClaimDesk window, so it rides on that window's
/// login — DualScreen never holds a password or token.
@MainActor
final class LiveCapture: ObservableObject {
    struct Result: Identifiable {
        let id = UUID()
        let lotNo: Int
        let lotFromScreen: Bool
        var cardName: String?
        var detail: String?
        var failed = false
    }

    @Published var results: [Result] = []
    @Published var busy = false
    @Published var error: String?
    /// Typed lot number; empty means read it off the screen.
    @Published var manualLot = ""

    private var lastLot = 0

    /// Shows run past midnight; like ClaimDesk, anything before 6am belongs
    /// to the previous day's show.
    static func showDate(_ now: Date = Date()) -> String {
        let cal = Calendar.current
        let day = cal.component(.hour, from: now) < 6
            ? cal.date(byAdding: .day, value: -1, to: now)!
            : now
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    static func isClaimDesk(_ w: WindowModel) -> Bool {
        guard w.kind == .web else { return false }
        let host = URL(string: w.text)?.host ?? ""
        return host.contains("timetocook") || w.title.localizedCaseInsensitiveContains("claimdesk")
    }

    // MARK: - Automatic

    /// Watching the auction. On Carousell Live the card is shown with its name
    /// BEFORE the lot number appears (the number only shows while the timer
    /// counts down), so frames are kept while no number is on screen, and when
    /// a new number appears those frames are what gets sent as that lot.
    @Published private(set) var auto = false
    @Published private(set) var watching: String?
    private var watcher: Task<Void, Never>?

    private static let pollSeconds: Double = 1.5
    /// Frames kept from the card-showing phase (about the last 15 seconds).
    private static let keepFrames = 10
    /// How many of those to try, newest first, before falling back to the countdown.
    private static let triesFromShowing = 3
    /// Countdown frames to try if none of the earlier ones was recognised.
    private static let countdownRetries: [Double] = [3, 8]

    func setAuto(_ on: Bool, auction: @escaping () -> WindowModel?, claimDesk: @escaping () -> WindowModel?) {
        watcher?.cancel()
        auto = on
        watching = nil
        guard on else { return }
        watcher = Task { [weak self] in
            var seen: Int?
            var showing: [Data] = []                 // frames with no lot number on screen
            var lotTask: Task<Void, Never>?
            while !Task.isCancelled {
                guard let self else { return }
                if let a = auction(), let c = claimDesk(),
                   let image = await WebViewStore.shared.fullSnapshot(a.id) {
                    if let lot = await Self.readLotNumber(image) {
                        self.watching = "lot \(lot) counting down"
                        if lot != seen {
                            seen = lot
                            let frames = Array(showing.reversed())   // newest first
                            showing = []
                            lotTask?.cancel()
                            lotTask = Task { await self.captureLot(lot, showing: frames, auction: a, claimDesk: c) }
                        }
                    } else {
                        if let jpeg = image.jpegData(compressionQuality: 0.85) {
                            showing.append(jpeg)
                            if showing.count > Self.keepFrames { showing.removeFirst() }
                        }
                        self.watching = "card on show · waiting for the lot number"
                    }
                } else {
                    self.watching = "open the auction and ClaimDesk windows"
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
            }
            lotTask?.cancel()
        }
    }

    /// One lot: try the frames from while the card was being shown, newest
    /// first, then a couple from the countdown, stopping once ClaimDesk
    /// recognises the card. Every try replaces the same lot's picture.
    private func captureLot(_ lot: Int, showing: [Data], auction: WindowModel, claimDesk: WindowModel) async {
        // Spread the tries across the showing phase rather than three
        // near-identical frames from its last few seconds.
        let step = max(1, showing.count / Self.triesFromShowing)
        for jpeg in stride(from: 0, to: showing.count, by: step).prefix(Self.triesFromShowing).map({ showing[$0] }) {
            if Task.isCancelled { return }
            if await send(jpeg, lot: lot, fromScreen: true, claimDesk: claimDesk) { return }
        }
        var elapsed: Double = 0
        for at in Self.countdownRetries {
            try? await Task.sleep(nanoseconds: UInt64((at - elapsed) * 1_000_000_000))
            elapsed = at
            if Task.isCancelled { return }           // the next lot has started
            guard let image = await WebViewStore.shared.fullSnapshot(auction.id),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else { continue }
            if let now = await Self.readLotNumber(image), now != lot { return }
            if await send(jpeg, lot: lot, fromScreen: true, claimDesk: claimDesk) { return }
        }
    }

    // MARK: - By hand

    func capture(auction: WindowModel, claimDesk: WindowModel) async {
        busy = true
        error = nil
        defer { busy = false }

        guard let image = await WebViewStore.shared.fullSnapshot(auction.id),
              let jpeg = image.jpegData(compressionQuality: 0.85) else {
            error = "Couldn't take a picture of the auction window."
            return
        }

        let typed = Int(manualLot.trimmingCharacters(in: .whitespaces))
        let read = typed == nil ? await Self.readLotNumber(image) : nil
        guard let lot = typed ?? read ?? (lastLot > 0 ? lastLot + 1 : nil) else {
            error = "Couldn't read a lot number off the screen. Type it in the Lot box."
            return
        }
        manualLot = ""
        _ = await send(jpeg, lot: lot, fromScreen: typed == nil && read != nil, claimDesk: claimDesk)
    }

    /// Post one picture as `lot`; true when ClaimDesk recognised the card.
    /// A retry of a lot already listed updates that row instead of adding one.
    @discardableResult
    private func send(_ jpeg: Data, lot: Int, fromScreen: Bool, claimDesk: WindowModel) async -> Bool {
        lastLot = lot
        var result = Result(lotNo: lot, lotFromScreen: fromScreen)
        var recognised = false
        do {
            let out = try await WebViewStore.shared.postImage(
                claimDesk.id,
                path: "/api/carousell/live-capture?date=\(Self.showDate())&lot_no=\(lot)",
                jpeg: jpeg)
            // The card's own name first — Japanese for a Japanese card — then
            // the English reading, the set and the number.
            result.cardName = out["card_name"] as? String
            let set = [out["card_name_en"] as? String,
                       (out["card_set_en"] as? String) ?? (out["card_set"] as? String),
                       out["card_number"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            recognised = out["recognised"] as? Bool == true
            result.detail = recognised ? set : "saved — not recognised; name it in ClaimDesk"
        } catch {
            result.failed = true
            result.detail = error.localizedDescription
        }
        if let i = results.firstIndex(where: { $0.lotNo == lot }) {
            results[i] = result
        } else {
            results.insert(result, at: 0)
        }
        return recognised
    }

    /// The lot number printed on the stream: "Lot 12", "Lot #12", else a bare "#12".
    static func readLotNumber(_ image: UIImage) async -> Int? {
        guard let cg = image.cgImage else { return nil }
        // perform() is synchronous, so the results are read straight after it
        // on the same background thread — one resume, whatever happens.
        let lines: [String] = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try? VNImageRequestHandler(cgImage: cg).perform([request])
                let obs = request.results ?? []
                done.resume(returning: obs.compactMap { $0.topCandidates(1).first?.string })
            }
        }
        let text = lines.joined(separator: "\n")
        for pattern in [#"(?i)\blot\s*(?:no\.?|number)?\s*#?\s*(\d{1,4})\b"#, #"#\s?(\d{1,4})\b"#] {
            if let m = text.range(of: pattern, options: .regularExpression),
               let n = text[m].range(of: #"\d{1,4}"#, options: .regularExpression),
               let lot = Int(text[m][n]), lot > 0 {
                return lot
            }
        }
        return nil
    }
}

/// The controller's panel: which window is the auction, the lot box, Capture,
/// and what each capture was recorded as.
struct LiveCapturePanel: View {
    @EnvironmentObject private var ws: Workspace
    @StateObject private var model = LiveCapture()
    @State private var auctionID: UUID?

    private var claimDesk: WindowModel? { ws.windows.first(where: LiveCapture.isClaimDesk) }
    private var auctions: [WindowModel] {
        ws.windows.filter { $0.kind == .web && !LiveCapture.isClaimDesk($0) }
    }
    private var auction: WindowModel? {
        auctions.first { $0.id == auctionID } ?? auctions.first
    }

    var body: some View {
        if let claimDesk, let auction {
            VStack(alignment: .leading, spacing: 8) {
                Text("LIVE AUCTION → CLAIMDESK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if auctions.count > 1 {
                        Picker("Auction", selection: Binding(get: { auction.id },
                                                             set: { auctionID = $0 })) {
                            ForEach(auctions) { Text($0.title).lineLimit(1).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Label(auction.title, systemImage: "globe")
                            .font(.footnote).lineLimit(1)
                    }
                    Spacer()
                    TextField("Lot (auto)", text: $model.manualLot)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                }

                // Its own full-width row: squeezed beside the lot box in a
                // narrow column, the label wrapped a few letters per line.
                Button {
                    Task { await model.capture(auction: auction, claimDesk: claimDesk) }
                } label: {
                    Group {
                        if model.busy { ProgressView() } else { Label("Capture lot", systemImage: "camera.viewfinder") }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)

                Toggle(isOn: Binding(
                    get: { model.auto },
                    set: { on in
                        model.setAuto(on, auction: { self.auction }, claimDesk: { self.claimDesk })
                    })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-capture each new lot").font(.callout)
                        Text(model.watching ?? "keeps pictures while the card is shown, files them when the lot number appears")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                ForEach(model.results.prefix(6)) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("#\(r.lotNo)").font(.callout.monospacedDigit().weight(.semibold))
                        if !r.lotFromScreen {
                            Image(systemName: "number.circle").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.failed ? "not saved" : (r.cardName ?? "unknown card"))
                                .font(.callout)
                                .foregroundStyle(r.failed ? .red : (r.cardName == nil ? .secondary : .primary))
                            if let d = r.detail, !d.isEmpty {
                                Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
