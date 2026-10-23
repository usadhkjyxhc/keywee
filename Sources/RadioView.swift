import SwiftUI

private struct DownTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct RadioView: View {
    private let startFreq: Double?
    private let startMode: String?

    @State private var activeHost: String
    @State private var activeTitle: String?
    @StateObject private var kiwi = KiwiClient()
    @ObservedObject private var library = Library.shared
    @AppStorage("lastFreq") private var lastFreq = 10000.0
    @AppStorage("lastReceiverHost") private var lastReceiverHost = ""
    @AppStorage("lastMode") private var lastMode = "am"

    @State private var baseZoom: Double?
    @State private var pinching = false
    @State private var panBase: Double?
    @State private var freqText = ""
    @FocusState private var typing: Bool
    @State private var showDebug = false
    @State private var showLibrary = false
    @State private var showFavSheet = false
    @State private var showInfo = false
    @State private var showSleep = false
    @State private var logDraft: LogDraft?

    /// On-screen height of one waterfall row (points). Smaller = more history, slower to fill.
    private static let rowPoints: CGFloat = 1.7

    /// Hot pink (255, 0, 165): the colour with the largest Lab distance to the heatmap palette.
    private let marker = Color(red: 1, green: 0, blue: 165.0 / 255)
    private let accent = Color(red: 1, green: 0.69, blue: 0)
    private let panel = Color(white: 0.06)

    private let bands: [(name: String, center: Double, range: ClosedRange<Double>)] = [
        ("49 m", 6000, 5800...6300), ("41 m", 7200, 7200...7500), ("31 m", 9600, 9300...10000),
        ("25 m", 11800, 11500...12200), ("19 m", 15300, 15000...15900),
        ("16 m", 17700, 17400...18000), ("13 m", 21600, 21400...21900)
    ]

    init(host: String, title: String? = nil, startFreq: Double? = nil, startMode: String? = nil) {
        _activeHost = State(initialValue: host)
        _activeTitle = State(initialValue: title)
        self.startFreq = startFreq
        self.startMode = startMode
    }

    /// Name as saved in the Receiver Atlas (falls back to the title it was opened with, then the address).
    private var receiverName: String {
        if let t = Atlas.title(for: activeHost), !t.isEmpty { return t }
        if let t = activeTitle, !t.isEmpty { return t }
        return activeHost
    }

    @ViewBuilder private var sleepLabel: some View {
        if let end = kiwi.sleepEnd {
            TimelineView(.periodic(from: .now, by: 20)) { _ in
                Text("\(max(1, Int(ceil(end.timeIntervalSinceNow / 60))))m")
                    .font(.caption.weight(.bold)).foregroundColor(accent)
            }
        } else {
            Image(systemName: "moon.zzz")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            stage.frame(maxHeight: .infinity)
            tuningBar
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showSleep = true } label: { sleepLabel }
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                Button { showLibrary = true } label: { Image(systemName: "book") }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLibrary) {
            LibrarySheet(host: activeHost, receiverName: receiverName, freq: kiwi.freq, mode: kiwi.mode,
                         onOpenFavorite: { fav in switchReceiver(host: fav.host) },
                         onOpenLog: { e in open(e) })
        }
        .sheet(isPresented: $showFavSheet) { FavoriteReceiverSheet(host: activeHost, defaultTitle: receiverName) }
        .sheet(isPresented: $showInfo) { ReceiverInfoSheet(kiwi: kiwi, host: activeHost, title: receiverName) }
        .sheet(isPresented: $showSleep) { SleepSheet(kiwi: kiwi) }
        .sheet(item: $logDraft) { d in LogEntrySheet(draft: d) }
        .onChange(of: kiwi.freq) { f in if !typing { freqText = fmt(f) } }
        .onChange(of: typing) { t in
            if t { freqText = "" } else { freqText = fmt(kiwi.freq) }
        }
        .onAppear {
            if let m = RadioMode(rawValue: startMode ?? lastMode) { kiwi.mode = m }
            let f = startFreq ?? lastFreq
            kiwi.jump(to: f, zoom: 0)          // always start fully zoomed out for an overview
            freqText = fmt(f)
            kiwi.receiverTitle = receiverName
            lastReceiverHost = activeHost
            kiwi.connect(host: activeHost)
        }
        .onDisappear {
            lastFreq = kiwi.freq
            lastMode = kiwi.mode.rawValue
            kiwi.cancelSleep()
            kiwi.disconnect()
        }
    }

    private func fmt(_ f: Double) -> String { String(format: "%.3f", f) }

    /// Listen on another receiver (same frequency and mode), fully zoomed out.
    private func switchReceiver(host: String) {
        let h = Atlas.normalize(host)
        guard !h.isEmpty, h != Atlas.normalize(activeHost) else { return }
        activeHost = host
        activeTitle = Atlas.title(for: host)
        lastReceiverHost = host
        kiwi.receiverTitle = receiverName
        kiwi.jump(to: kiwi.freq, zoom: 0)
        kiwi.connect(host: host)
    }

    /// Opens a logbook entry: only on the receiver it was logged on. The receiver is added to the
    /// Atlas (titled with its address) if it is not there yet.
    private func open(_ e: LogEntry) {
        guard let h = e.host, !h.isEmpty else { return }
        Atlas.ensure(host: h)
        if let m = RadioMode(rawValue: e.mode) { kiwi.mode = m }
        if Atlas.normalize(h) != Atlas.normalize(activeHost) {
            activeHost = h
            activeTitle = Atlas.title(for: h)
            lastReceiverHost = h
            kiwi.receiverTitle = receiverName
            kiwi.jump(to: e.freq, zoom: 0)
            kiwi.connect(host: h)
        } else {
            kiwi.tune(to: e.freq)
        }
    }

    // MARK: Waterfall

    private var stage: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let span = kiwi.viewSpan, start = kiwi.viewStart
            let mx = CGFloat((kiwi.freq - start) / span) * w
            let pb = kiwi.mode.passband
            let x0 = CGFloat((kiwi.freq + Double(pb.low) / 1000 - start) / span) * w
            let x1 = CGFloat((kiwi.freq + Double(pb.high) / 1000 - start) / span) * w

            ZStack {
                waterfallLayer(w: w, h: h, mx: mx, x0: x0, x1: x1)
                // The zoom buttons are siblings of the gesture layer, so tapping them never tunes.
                VStack(spacing: 8) {
                    zoomButton("plus") { kiwi.setZoom(kiwi.zoomLevel + 1) }
                    zoomButton("minus") { kiwi.setZoom(kiwi.zoomLevel - 1) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(10)
            }
            .onAppear { kiwi.setVisibleRows(Int(h / Self.rowPoints)) }
            .onChange(of: h) { nh in kiwi.setVisibleRows(Int(nh / Self.rowPoints)) }
        }
        .clipped()
    }

    private func waterfallLayer(w: CGFloat, h: CGFloat, mx: CGFloat, x0: CGFloat, x1: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let img = kiwi.waterfall {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: w, height: h)
            }
            // passband shading + cursor line
            Rectangle().fill(marker.opacity(0.16))
                .frame(width: max(1.5, x1 - x0), height: h)
                .offset(x: x0)
                .allowsHitTesting(false)
            Rectangle().fill(marker)
                .frame(width: 1.5, height: h)
                .shadow(color: marker.opacity(0.9), radius: 3)
                .offset(x: mx - 0.75)
                .allowsHitTesting(false)
            DownTriangle().fill(marker)
                .frame(width: 12, height: 8)
                .offset(x: mx - 6, y: 22)
                .allowsHitTesting(false)

            axis
                .frame(height: 24)
                .background(LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)],
                                           startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)

            if kiwi.status != "Connected" {
                Text(kiwi.status)
                    .font(.caption.weight(.medium))
                    .foregroundColor(accent)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 38).padding(.leading, 10)
                    .frame(maxWidth: w * 0.8, alignment: .leading)
                    .allowsHitTesting(false)
            }

            if showDebug {
                Text(kiwi.debug)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .contentShape(Rectangle())
        // One finger: pan. Two fingers: zoom. Tap: tune there.
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    guard !pinching else { return }
                    if panBase == nil { panBase = kiwi.viewStart }
                    kiwi.setViewStart((panBase ?? 0) - Double(v.translation.width / w) * kiwi.viewSpan)
                }
                .onEnded { _ in panBase = nil }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { tap in
                    guard !pinching else { return }
                    tune(atX: tap.location.x, width: w)
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    pinching = true
                    panBase = nil
                    if baseZoom == nil { baseZoom = kiwi.zoomLevel }
                    kiwi.setZoom((baseZoom ?? 0) + log2(Double(scale)))
                }
                .onEnded { _ in
                    baseZoom = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pinching = false }
                }
        )
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Frequency scale with major/minor ticks along the top edge (labels in MHz).
    private var axis: some View {
        Canvas { ctx, size in
            let span = kiwi.viewSpan, start = kiwi.viewStart
            let step = niceStep(span / 6)
            let decimals = max(0, Int(ceil(-log10(step / 1000))))
            let minor = step / 5
            let i0 = Int(ceil(start / minor)), i1 = Int(floor((start + span) / minor))
            guard i1 >= i0, i1 - i0 < 600 else { return }
            for i in i0...i1 {
                let f = Double(i) * minor
                let x = CGFloat((f - start) / span) * size.width
                let major = i % 5 == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x, y: size.height - (major ? 8 : 4)))
                ctx.stroke(p, with: .color(.white.opacity(major ? 0.85 : 0.4)), lineWidth: 1)
                if major {
                    let t = Text(String(format: "%.\(decimals)f", f / 1000))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                    ctx.draw(t, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
            }
            let unit = Text("MHz").font(.system(size: 9, weight: .semibold)).foregroundColor(accent)
            ctx.draw(unit, at: CGPoint(x: size.width - 4, y: size.height - 11), anchor: .bottomTrailing)
        }
    }

    private func niceStep(_ raw: Double) -> Double {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
        return steps.first { $0 >= raw } ?? 5000
    }

    private func tune(atX x: CGFloat, width: CGFloat) {
        typing = false
        let frac = max(0, min(1, Double(x / width)))
        kiwi.tune(to: kiwi.viewStart + frac * kiwi.viewSpan)
    }

    // MARK: Tuning bar (directly under the waterfall, thumb lines up with the cursor)

    private var tuningBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let raw = (kiwi.freq - kiwi.viewStart) / kiwi.viewSpan
            let inView = raw >= 0 && raw <= 1
            let x = CGFloat(min(1, max(0, raw))) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 2)
                Capsule().fill(marker.opacity(inView ? 1 : 0.35))
                    .frame(width: 10, height: 24)
                    .offset(x: min(max(x - 5, 0), w - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in tune(atX: v.location.x, width: w) }
            )
        }
        .frame(height: 36)
        .background(panel)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField(fmt(kiwi.freq), text: $freqText)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.go)
                    .focused($typing)
                    .onSubmit { commitFreq() }
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("kHz").font(.subheadline.weight(.medium)).foregroundColor(.secondary)
                Spacer(minLength: 8)
                sMeter
                    .onLongPressGesture { showDebug.toggle() }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("All", selected: kiwi.zoomLevel < 0.05) { kiwi.jump(to: kiwi.freq, zoom: 0) }
                    ForEach(bands, id: \.name) { b in
                        chip(b.name, selected: b.range.contains(kiwi.freq)) {
                            kiwi.jump(to: b.center, zoom: 5)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach([-5.0, -1.0, 1.0, 5.0], id: \.self) { d in
                    Button { kiwi.step(d) } label: {
                        Text(d < 0 ? "−\(Int(-d))" : "+\(Int(d))")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 2) {
                ForEach(RadioMode.allCases) { m in
                    Button { kiwi.mode = m } label: {
                        Text(m.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(kiwi.mode == m ? .white : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(kiwi.mode == m ? Color.white.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button { kiwi.togglePlayPause() } label: {
                    Image(systemName: kiwi.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundColor(.black)
                        .frame(width: 46, height: 46)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                Image(systemName: "speaker.fill").foregroundColor(.secondary)
                Slider(value: Binding(get: { Double(kiwi.volume) },
                                      set: { kiwi.volume = Float($0) }), in: 0...1)
                    .tint(accent)
                quickButton(isFavorite ? "star.fill" : "star", highlighted: isFavorite) { showFavSheet = true }
                quickButton("square.and.pencil") {
                    logDraft = LogDraft(freq: kiwi.freq, mode: kiwi.mode.rawValue,
                                        receiver: receiverName, date: Date(),
                                        host: activeHost, receiverTitle: receiverName)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
        .background(panel)
    }

    private var isFavorite: Bool {
        library.favorite(for: activeHost) != nil
    }

    private func quickButton(_ symbol: String, highlighted: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(highlighted ? accent : .white)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: S-meter

    private func sLabel(_ dbm: Double) -> String {
        if dbm > -73 { return "S9+\(Int((dbm + 73).rounded()))" }
        return "S\(max(0, min(9, Int(((dbm + 127) / 6).rounded()))))"
    }

    private var sMeter: some View {
        let frac = CGFloat(min(1, max(0, (kiwi.smeter + 127) / 94)))
        return VStack(alignment: .trailing, spacing: 4) {
            Text(sLabel(kiwi.smeter))
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundColor(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(accent).frame(width: 70 * frac)
            }
            .frame(width: 70, height: 4)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundColor(selected ? accent : .secondary)
                .background(selected ? accent.opacity(0.18) : Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Enter on the keyboard: under 30 is read as MHz, otherwise kHz.
    private func commitFreq() {
        let t = freqText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        typing = false
        if let v = Double(t), v > 0 { kiwi.tune(to: v < 30 ? v * 1000 : v) }
        freqText = fmt(kiwi.freq)
    }
}
