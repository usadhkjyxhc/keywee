import SwiftUI
import UIKit
import MediaPlayer

enum RadioMode: String, CaseIterable, Identifiable {
    case am, usb, lsb, cw
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var passband: (low: Int, high: Int) {
        switch self {
        case .am:  return (-4900, 4900)
        case .usb: return (300, 2700)
        case .lsb: return (-2700, -300)
        case .cw:  return (300, 800)
        }
    }
}

/// Spricht das KiwiSDR-WebSocket-Protokoll (Audio "SND" + Wasserfall "W/F").
@MainActor
final class KiwiClient: ObservableObject {
    static let maxKHz = 30000.0
    static let bins = 1024
    static let maxZoom = 14.0
    // Waterfall tuning knobs (untested defaults; adjust if the picture is too dark / too colourful)
    static let imgWidth = 960         // pixels per rendered waterfall row
    static let floorOffset = -4.0     // noise floor sits this many dB above the darkest colour
    static let rangeDB = 60.0         // dB between darkest and brightest colour

    struct WFRow { let bins: [UInt8]; let start: Double; let span: Double }

    @Published var status = "Disconnected"
    @Published var debug = ""
    var sndCount = 0, wfCount = 0, lastMsg = "", lastTag = ""
    @Published var smeter = -127.0
    @Published var waterfall: UIImage?
    @Published var freq = 10000.0 { didSet { updateNowPlaying() } }
    @Published var isPlaying = false
    @Published var sleepEnd: Date?
    /// KiwiSDR waterfall rate: 1 = slowest ... 4 = fastest. Lower values mean less data and CPU.
    @Published var wfSpeed = UserDefaults.standard.object(forKey: "wfSpeed") as? Int ?? 3 {
        didSet {
            UserDefaults.standard.set(wfSpeed, forKey: "wfSpeed")
            if let w = wf { send(w, "SET wf_speed=\(wfSpeed)") }
        }
    }
    var bytesIn = 0                       // audio + waterfall payload since the last connect
    private var lastSmeterAt = Date.distantPast
    /// Average stream data rate in kB/s since connecting (includes the first seconds of start-up)
    var dataRate: Double {
        guard let c = connectedAt else { return 0 }
        let t = Date().timeIntervalSince(c)
        return t > 1 ? Double(bytesIn) / 1024 / t : 0
    }
    private var sleepTask: Task<Void, Never>?
    private var lastHost = ""
    private var gen = 0
    private var floorEst = 0.0                       // laufend geschätzter Rauschteppich (Byte-Wert)
    private var ignoreRowsUntil = Date.distantPast   // Zeilen kurz verwerfen, bis der neue Ausschnitt ankommt
    private var remoteReady = false
    @Published var mode = RadioMode.am { didSet { sendTune(); updateNowPlaying() } }
    // Start zoomed in (about 0.9 MHz visible) instead of the whole 0-30 MHz
    @Published var zoomLevel = 5.0
    @Published var viewStart = 10000.0 - KiwiClient.maxKHz / 64
    @Published var viewSpan = KiwiClient.maxKHz / 32
    @Published var volume: Float = 1 { didSet { audio.setVolume(volume) } }

    private let session = URLSession(configuration: .default)
    private let audio = AudioOut()
    private var snd: URLSessionWebSocketTask?
    private var wf: URLSessionWebSocketTask?
    private var keepalive: Task<Void, Never>?
    private var rows: [WFRow] = []
    /// Number of rows that fit on screen (set by the view). Rows keep a constant height.
    var visibleRows = 360
    var receiverTitle = ""
    private var rowTimes: [TimeInterval] = []
    var lastClose = ""
    /// key=value pairs the receiver reported in its "MSG" frames (shown in the info sheet)
    var serverInfo: [String: String] = [:]
    var currentHost: String { lastHost }
    var wfRate: Double {
        guard rowTimes.count > 5, let f = rowTimes.first, let l = rowTimes.last, l > f else { return 0 }
        return Double(rowTimes.count - 1) / (l - f)
    }
    private var reconnectTimes: [Date] = []
    private var hadAudio = false            // did the current connection deliver audio?
    private var arAcked = false
    private var connectedAt: Date?
    private var reconnectPending = false
    /// Connection history (newest last), shown in the info sheet.
    var eventLog: [String] = []

    private func logEvent(_ text: String) {
        eventLog.append("\(GMT.time(Date())) \(text)")
        if eventLog.count > 40 { eventLog.removeFirst() }
    }
    private var serverZoom = -1
    private var serverStart = 0.0
    private var serverSpan = KiwiClient.maxKHz
    private var lastRender = Date.distantPast
    // Heatmap: black -> deep blue -> blue -> cyan -> green -> yellow -> red (packed as R,G,B,X bytes)
    private let palette: [UInt32] = {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0, 0, 0)), (0.20, (0, 0, 120)), (0.38, (0, 50, 255)),
            (0.52, (0, 200, 255)), (0.64, (0, 230, 60)), (0.78, (255, 235, 0)),
            (0.90, (255, 60, 0)), (1.00, (255, 0, 0))]
        return (0..<256).map { i in
            let t = Double(i) / 255
            var k = 0
            while k < stops.count - 2 && t > stops[k + 1].0 { k += 1 }
            let (t0, c0) = stops[k], (t1, c1) = stops[k + 1]
            let u = min(1, max(0, (t - t0) / (t1 - t0)))
            let r = UInt32(c0.0 + (c1.0 - c0.0) * u)
            let g = UInt32(c0.1 + (c1.1 - c0.1) * u)
            let b = UInt32(c0.2 + (c1.2 - c0.2) * u)
            return 0xFF00_0000 | (b << 16) | (g << 8) | r
        }
    }()

    // MARK: Verbindung

    func connect(host: String) {
        disconnect()
        lastHost = host
        lastMsg = ""
        serverInfo = [:]
        sndCount = 0; wfCount = 0; rowTimes = []; bytesIn = 0
        hadAudio = false
        arAcked = false
        reconnectPending = false
        connectedAt = Date()
        logEvent("connecting to \(host)")
        isPlaying = true
        setupRemoteCommands()
        status = "Connecting …"
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let sURL = URL(string: "ws://\(host)/kiwi/\(ts)/SND"),
              let wURL = URL(string: "ws://\(host)/kiwi/\(ts)/W/F") else {
            status = "Invalid address"; return
        }
        let s = session.webSocketTask(with: sURL)
        let w = session.webSocketTask(with: wURL)
        snd = s; wf = w
        s.resume(); w.resume()

        send(s, "SET auth t=kiwi p=")
        send(s, "SET AR OK in=12000 out=44100")
        send(s, "SET compression=0")
        send(s, "SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 manGain=50")
        send(s, "SET ident_user=Keywee")
        sendTune()

        send(w, "SET auth t=kiwi p=")
        send(w, "SET wf_speed=\(wfSpeed)")
        send(w, "SET wf_comp=0")
        send(w, "SET maxdb=-10 mindb=-110")
        serverZoom = -1
        floorEst = 0
        ensureServerView()

        audio.start()
        listen(s, isWaterfall: false)
        listen(w, isWaterfall: true)
        updateNowPlaying()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if let s = self.snd { self.send(s, "SET keepalive") }
                if let w = self.wf { self.send(w, "SET keepalive") }
            }
        }
    }

    private func teardown() {
        gen += 1
        keepalive?.cancel()
        snd?.cancel(with: .goingAway, reason: nil)
        wf?.cancel(with: .goingAway, reason: nil)
        snd = nil; wf = nil
        audio.stop()
    }

    /// Verlässt den Empfänger komplett (Sperrbildschirm-Player verschwindet).
    func disconnect() {
        reconnectPending = false
        teardown()
        rows.removeAll()
        waterfall = nil
        status = "Disconnected"
        isPlaying = false
        lastHost = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Sleep timer

    /// Turns the radio off after the given minutes; the volume fades out during the last 20 seconds.
    func startSleep(minutes: Int) {
        cancelSleep()
        sleepEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let end = self.sleepEnd else { return }
                let left = end.timeIntervalSinceNow
                if left <= 0 {
                    self.sleepEnd = nil
                    self.sleepTask = nil
                    self.pause()
                    self.audio.setVolume(self.volume)
                    self.status = "Sleep timer ended"
                    return
                }
                if left < 20 { self.audio.setVolume(self.volume * Float(left / 20)) }
            }
        }
    }

    func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEnd = nil
        audio.setVolume(volume)
    }

    // MARK: Sperrbildschirm / Play-Pause

    /// Pause = Verbindung trennen (spart Datenverkehr und Serverplatz), Play = neu verbinden.
    func pause() {
        reconnectPending = false
        guard isPlaying else { return }
        logEvent("paused")
        teardown()
        isPlaying = false
        status = "Paused"
        updateNowPlaying()
    }

    func resume() {
        guard !isPlaying, !lastHost.isEmpty else { return }
        connect(host: lastHost)
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    private func setupRemoteCommands() {
        guard !remoteReady else { return }
        remoteReady = true
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        c.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        // Schritt vor/zurück stimmt um 5 kHz ab (praktisch zum Bandsuchen vom Sperrbildschirm)
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.step(5) }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.step(-5) }; return .success
        }
    }

    private static let artwork: MPMediaItemArtwork? = {
        guard let img = UIImage(named: "NowPlayingArt") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }()

    private func updateNowPlaying() {
        guard !lastHost.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: String(format: "%.3f kHz · %@", freq, mode.label),
            MPMediaItemPropertyArtist: receiverTitle.isEmpty ? lastHost : receiverTitle,
            MPMediaItemPropertyAlbumTitle: "Keywee",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let a = Self.artwork { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func send(_ t: URLSessionWebSocketTask, _ text: String) {
        t.send(.string(text)) { _ in }
    }

    private func listen(_ task: URLSessionWebSocketTask, isWaterfall: Bool) {
        let g = gen
        Task { [weak self] in
            while true {
                do {
                    let msg = try await task.receive()
                    guard let self, g == self.gen else { return }
                    self.handle(msg, isWaterfall: isWaterfall)
                } catch {
                    // Nur melden, wenn die Verbindung unerwartet abbricht (nicht bei Pause/Neuverbinden)
                    guard let self, g == self.gen else { return }
                    self.connectionLost(task: task, error: error, isWaterfall: isWaterfall)
                    return
                }
            }
        }
    }

    /// Unexpected close: say why (server message / close code), and reconnect on its own
    /// up to 3 times per 2 minutes unless the receiver told us to go away.
    private func connectionLost(task: URLSessionWebSocketTask, error: Error, isWaterfall: Bool) {
        var parts: [String] = []
        if task.closeCode != .invalid { parts.append("code \(task.closeCode.rawValue)") }
        if let r = task.closeReason, let t = String(data: r, encoding: .utf8), !t.isEmpty { parts.append(t) }
        if parts.isEmpty { parts.append((error as NSError).localizedDescription) }
        let reason = parts.joined(separator: ", ")
        lastClose = reason
        let host = lastHost
        let key = lastKey
        // Start-up messages like too_busy=1 also appear on receivers that accept us, so they only
        // count when the connection never delivered audio.
        let busy = (flag("too_busy") || lastMsg.contains("all_busy")) && !hadAudio
        let pwd = flag("badp") && !hadAudio
        let kicked = key.hasPrefix("inactivity") || key.contains("kick") || key.contains("ip_limit") || key == "down"
        let denied = pwd || kicked
        let alive = connectedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        logEvent("\(isWaterfall ? "waterfall" : "audio") socket closed after \(alive)s (\(reason)), \(String(format: "%.0f kB/s, %.0f rows/s", dataRate, wfRate)), speed \(wfSpeed), last message: \(lastMsg.isEmpty ? "none" : lastMsg)")
        teardown()
        isPlaying = false
        updateDebug()
        reconnectTimes = reconnectTimes.filter { Date().timeIntervalSince($0) < 240 }
        let attempt = reconnectTimes.count
        // A dead connection can keep its slot on the server for a while, so the waits grow
        let delays: [Double] = [2, 6, 15, 30, 45]
        // "busy" is only retried when the receiver worked before (its slot may need a moment to free up)
        let retryBusy = busy && (hadAudio || attempt > 0)
        if !denied, !host.isEmpty, attempt < delays.count, !busy || retryBusy {
            reconnectTimes.append(Date())
            let delay = delays[attempt]
            reconnectPending = true
            status = (busy ? "Receiver busy" : "Connection lost") + " · retry \(attempt + 1)/\(delays.count) in \(Int(delay)) s"
            logEvent("retry \(attempt + 1) in \(Int(delay)) s")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.reconnectPending, self.lastHost == host else { return }
                self.reconnectPending = false
                self.connect(host: host)
            }
        } else if busy {
            status = "Receiver refused the connection (too_busy)"
        } else if pwd {
            status = "Password required"
        } else if denied {
            status = "Closed by receiver: " + lastMsg
        } else {
            status = "Connection closed (" + reason + ")"
        }
        updateNowPlaying()
    }

    // MARK: Empfang

    private func handle(_ msg: URLSessionWebSocketTask.Message, isWaterfall: Bool) {
        switch msg {
        case .string(let s):
            handleMessage(s)
        case .data(let d):
            let b = [UInt8](d)
            if b.count > 10, b[0] == 0x53, b[1] == 0x4E, b[2] == 0x44 {      // "SND"
                status = "Connected"
                if !hadAudio { hadAudio = true; logEvent("audio started") }
                sndCount += 1
                let flags = b[3]
                bytesIn += b.count
                let sm = Double(UInt16(b[8]) << 8 | UInt16(b[9]))
                if Date().timeIntervalSince(lastSmeterAt) > 0.25 {     // fewer UI refreshes
                    smeter = sm * 0.1 - 127
                    lastSmeterAt = Date()
                }
                if flags & 0x10 == 0 { audio.push(Array(b[10...])) }          // unkomprimiert
            } else if b.count >= 3 + Self.bins, b[0] == 0x57, b[1] == 0x2F, b[2] == 0x46 { // "W/F"
                wfCount += 1
                bytesIn += b.count
                addRow(Array(b.suffix(Self.bins)))
            } else if b.count >= 3, b[0] == 0x4D, b[1] == 0x53, b[2] == 0x47 {              // "MSG"
                let text = String(decoding: b.dropFirst(3), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                handleMessage(text)
            } else {
                lastTag = String(decoding: b.prefix(3), as: UTF8.self) + " (\(b.count) B)"
            }
            if (sndCount + wfCount) % 25 == 0 { updateDebug() }
        @unknown default: break
        }
    }

    private func handleMessage(_ s: String) {
        lastMsg = String(s.prefix(70))
        for tok in s.split(separator: " ") {
            guard let eq = tok.firstIndex(of: "="), serverInfo.count < 120 else { continue }
            let k = String(tok[..<eq])
            guard !k.isEmpty, k.count < 40 else { continue }
            let raw = String(tok[tok.index(after: eq)...])
            serverInfo[k] = String((raw.removingPercentEncoding ?? raw).prefix(200))
        }
        // The receiver announces its audio rate; the client has to answer with "SET AR OK ..."
        // (the browser and the reference Python client do this). Without it the receiver may drop us.
        if !arAcked, let r = serverInfo["audio_rate"], let s = snd {
            let rate = Int(Double(r) ?? 12000)
            send(s, "SET AR OK in=\(rate) out=44100")
            arAcked = true
            logEvent("sent audio-rate acknowledgement (\(rate) Hz)")
        }
        updateDebug()
    }

    private func flag(_ key: String) -> Bool { (Int(serverInfo[key] ?? "") ?? 0) > 0 }

    /// Name of the last server message ("too_busy" in "too_busy=0")
    private var lastKey: String { String(lastMsg.prefix { $0 != "=" && $0 != " " }).lowercased() }

    private func updateDebug() {
        var rate = ""
        if rowTimes.count > 5, let f = rowTimes.first, let l = rowTimes.last, l > f {
            rate = String(format: " (%.0f rows/s)", Double(rowTimes.count - 1) / (l - f))
        }
        debug = "Audio \(sndCount) · Waterfall \(wfCount)\(rate)" + (lastMsg.isEmpty ? "" : " · \(lastMsg)")
            + (lastTag.isEmpty ? "" : " · ?\(lastTag)") + (lastClose.isEmpty ? "" : " · closed: \(lastClose)")
    }

    private func addRow(_ row: [UInt8]) {
        if Date() < ignoreRowsUntil { return }
        rowTimes.append(Date().timeIntervalSince1970)
        if rowTimes.count > 40 { rowTimes.removeFirst() }
        // Rauschteppich = 20-%-Perzentil der Zeile (Signale belegen nur einen kleinen Teil des Spektrums)
        var sorted = row; sorted.sort()
        let est = Double(sorted[sorted.count / 5])
        floorEst = floorEst == 0 ? est : floorEst * 0.97 + est * 0.03
        rows.insert(WFRow(bins: row, start: serverStart, span: serverSpan), at: 0)
        while rows.count > max(1, visibleRows) { rows.removeLast() }
        guard Date().timeIntervalSince(lastRender) > 0.1 else { return }
        lastRender = Date()
        renderImage()
    }

    private func renderImage() {
        let w = Self.imgWidth, h = max(1, visibleRows)
        guard !rows.isEmpty else { return }
        var px = [UInt32](repeating: palette[0], count: w * h)
        let wfMin = floorEst + Self.floorOffset
        let k = 255.0 / Self.rangeDB
        let bins = Self.bins
        let vs = viewStart, vp = viewSpan
        px.withUnsafeMutableBufferPointer { p in
            for (y, row) in rows.prefix(h).enumerated() {
                let scale = Double(bins) / row.span
                let base = y * w
                row.bins.withUnsafeBufferPointer { b in
                    for x in 0..<w {
                        let f = vs + (Double(x) + 0.5) / Double(w) * vp
                        if f < row.start { continue }
                        let idx = Int((f - row.start) * scale)
                        if idx >= bins { continue }
                        let n = (Double(b[idx]) - wfMin) * k
                        p[base + x] = palette[Int(min(255, max(0, n)))]
                    }
                }
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)
        else { return }
        waterfall = UIImage(cgImage: img)
    }

    /// Called by the view when its height is known; keeps every row at the same on-screen height.
    func setVisibleRows(_ n: Int) {
        let v = max(60, min(900, n))
        guard v != visibleRows else { return }
        visibleRows = v
        while rows.count > v { rows.removeLast() }
        renderImage()
    }

    // MARK: Steuerung

    func sendTune() {
        guard let s = snd else { return }
        let p = mode.passband
        send(s, String(format: "SET mod=%@ low_cut=%d high_cut=%d freq=%.3f",
                       mode.rawValue, p.low, p.high, freq))
    }

    /// Abstimmen. Der Ausschnitt bleibt stehen, solange die Frequenz sichtbar ist.
    func tune(to khz: Double) {
        freq = min(Self.maxKHz, max(10, khz))
        if freq < viewStart || freq > viewStart + viewSpan {
            viewStart = min(Self.maxKHz - viewSpan, max(0, freq - viewSpan / 2))
            ensureServerView()
            renderImage()
        }
        sendTune()
    }

    func step(_ delta: Double) { tune(to: freq + delta) }

    /// Stufenloser Zoom. Der Frequenzstrich bleibt dabei an derselben Bildschirmposition.
    func setZoom(_ z: Double) {
        let frac = viewSpan > 0 ? min(1, max(0, (freq - viewStart) / viewSpan)) : 0.5
        zoomLevel = min(Self.maxZoom, max(0, z))
        viewSpan = Self.maxKHz / pow(2, zoomLevel)
        viewStart = min(Self.maxKHz - viewSpan, max(0, freq - frac * viewSpan))
        ensureServerView()
        renderImage()
    }

    /// Verschiebt den sichtbaren Ausschnitt (Wasserfall mit dem Finger schieben).
    func setViewStart(_ start: Double) {
        let clamped = min(Self.maxKHz - viewSpan, max(0, start))
        guard clamped != viewStart else { return }
        viewStart = clamped
        ensureServerView()
        renderImage()
    }

    /// Springt auf eine Frequenz und zoomt auf die gewünschte Stufe.
    func jump(to khz: Double, zoom z: Double) {
        freq = min(Self.maxKHz, max(10, khz))
        zoomLevel = min(Self.maxZoom, max(0, z))
        viewSpan = Self.maxKHz / pow(2, zoomLevel)
        viewStart = min(Self.maxKHz - viewSpan, max(0, freq - viewSpan / 2))
        sendTune()
        ensureServerView()
        renderImage()
    }

    /// Der Server liefert ganzzahlige Zoomstufen. Wir fordern die Stufe darunter an
    /// und schneiden den gewünschten Ausschnitt selbst zu.
    private func ensureServerView() {
        let zInt = Int(zoomLevel)
        let sSpan = Self.maxKHz / pow(2, Double(zInt))
        let covered = zInt == serverZoom
            && viewStart >= serverStart - 0.001
            && viewStart + viewSpan <= serverStart + serverSpan + 0.001
        if covered { return }
        if zInt != serverZoom { rows.removeAll() }   // andere Auflösung → alte Zeilen passen nicht mehr
        serverZoom = zInt
        serverSpan = sSpan
        serverStart = min(Self.maxKHz - sSpan, max(0, viewStart + viewSpan / 2 - sSpan / 2))
        guard let w = wf else { return }
        ignoreRowsUntil = Date().addingTimeInterval(0.6)
        send(w, String(format: "SET zoom=%d cf=%.3f", zInt, serverStart + sSpan / 2))
    }
}
