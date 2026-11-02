import SwiftUI
import Foundation

// MARK: - Endpoints (JSX CMD + the control server on :8090)
// Not hardcoded: the Server tab edits one base URL (`scheme://host`), persisted in
// UserDefaults, and every endpoint is derived from it — metrics on :8080, control
// on :8090. The field accepts `192.168.1.13`, `http://host` or a full
// `http://host:8080/metrics`; the scheme/host is kept, path and port are replaced.

// Own suite, so the value lands in ~/Library/Preferences/com.strata.widget.plist
// rather than the global domain (this binary has no bundle identifier).
let strataDefaults = UserDefaults(suiteName: "com.strata.widget")!
let baseURLKey = "strata.baseURL"
let defaultBaseURL = "http://192.168.1.13"
let metricsPort = 8080
let controlPort = 8090

let apiKey = "strata" // server --api-key; every request carries it as Authorization: Bearer

// nil when the text can't name a host; the caller keeps the draft visible instead.
func normalizeBase(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    let lowered = s.lowercased()
    if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") { s = "http://" + s }
    guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
    c.path = "" // endpoints append their own path
    c.port = nil // metrics/control ports are fixed
    c.query = nil
    c.fragment = nil
    return c.url?.absoluteString
}

func endpoint(_ path: String, port: Int) -> String? {
    guard var c = URLComponents(string: strata.baseURL) else { return nil }
    c.path = path
    c.port = port
    return c.url?.absoluteString
}

func metricsURL() -> String? { endpoint("/metrics", port: metricsPort) }
func controlURL(_ cmd: String) -> String? { endpoint("/\(cmd)", port: controlPort) }
func startCoderURL() -> String? { controlURL("start-coder") }
func startGyroMURL() -> String? { controlURL("start-gyro") }
func stopURL() -> String? { controlURL("stop") }

// Host-only view of the base URL for captions ("192.168.1.13:8080 unreachable").
func hostLabel() -> String {
    if let c = URLComponents(string: strata.baseURL), let host = c.host, !host.isEmpty { return host }
    return strata.baseURL
}

let GiB = 1_073_741_824.0 // JSX `GiB = 1073741824`

func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

// MARK: - Fetch
// No header API survives in this Foundation build: every URLSession/URLRequest
// route is bypassed on purpose — /usr/bin/curl carries the Authorization header
// and does the request. (The old system(3) call is gone: the macOS SDK marks
// `system` unavailable in Swift, and Foundation.Process is the supported way to
// spawn a child process.) Verified live: `Bearer strata` → 200 on :8080/metrics,
// missing key → 401. curl -m 3 mirrors the JSX timeout.

func fetchBody(_ url: String?) async -> String? {
    guard let url, let target = URL(string: url) else { return nil }
    // Per-endpoint temp file (port+path+pid): polls never race each other.
    let name = String(target.path.map { c in (c.isLetter || c.isNumber) ? c : "-" }) // "/metrics" → "-metrics-"
    let tmp = "/tmp/strata-fetch-\(target.port ?? 0)-\(name)-\(getpid()).json"
    defer { _ = remove(tmp) } // unlink after the read below
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-s", "-m", "3",
                      "-H", "Authorization: Bearer \(apiKey)",
                      "-o", tmp, url]
    do {
        try curl.run()
    } catch {
        return nil // spawn failures yield nil; body validity judged by the decode below
    }
    curl.waitUntilExit() // sync wait: a curl never outlives its -m 3 timeout
    return try? String(contentsOf: URL(fileURLWithPath: tmp), encoding: .utf8)
}

// Fire-and-forget control GETs; /stop can take ~40s, so never block the UI.
func runControl(_ url: String?) { Task { _ = await fetchBody(url) } }

// MARK: - Shared state (JSX module-level `let tab / startTs / spinI`)

@Observable final class StrataState {
    var payload: MetricsPayload? = nil
    var tab = "metrics"
    var startTsMs: Int? = nil
    var spinFrame = 0
    // Persisted server base URL; urlText is the field's live draft, so typing
    // mid-edit never repoints the poller.
    var baseURL: String = strataDefaults.string(forKey: baseURLKey) ?? defaultBaseURL
    var urlText: String = strataDefaults.string(forKey: baseURLKey) ?? defaultBaseURL
    var urlError: String? = nil
}
let strata = StrataState()

// Commit the field on Return / Apply: normalize, persist, repoint the poller, and
// drop the stale payload so the card re-reads from the new host right away.
func commitURL() {
    guard let base = normalizeBase(strata.urlText) else {
        strata.urlError = "not a host · still polling \(hostLabel())"
        return
    }
    strata.urlError = nil
    if base != strata.baseURL {
        strata.baseURL = base
        strata.urlText = base
        strataDefaults.set(base, forKey: baseURLKey)
        strata.payload = nil
        strata.startTsMs = nil
    }
}

// The poller replaces refreshFrequency=1000 + curl -m 3: one long-running Task
// loop, decode, assign, sleep 1s. Spawned once when the app struct initializes.
func startPolling() {
    Task {
        while !Task.isCancelled {
            var parsed: MetricsPayload? = nil
            if let url = metricsURL(), let body = await fetchBody(url) {
                parsed = try? JSONDecoder().decode(MetricsPayload.self, from: Data(body.utf8))
            }
            strata.payload = parsed
            if parsed != nil { strata.startTsMs = nil } // a successful parse clears "starting"
            if strata.startTsMs != nil { strata.spinFrame += 1 } // spinner advances ~1 glyph/s
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - Small view helpers

func tabPillsRow() -> some View {
    HStack(spacing: 6) {
        pillView(text: "Metrics", active: strata.tab == "metrics")
            .onTapGesture { strata.tab = "metrics" }
        pillView(text: "Server", active: strata.tab == "server")
            .onTapGesture { strata.tab = "server" }
    }
    .padding(.top, 10)
    .padding(.bottom, 8)
}

func headerRow(_ pill: String, _ pillColor: Color) -> some View {
    HStack {
        Text("Strata")
            .font(.custom("Outfit", size: 13)).fontWeight(.bold)
            .tracking(0.4)
            .foregroundStyle(cText)
            .frame(maxWidth: .infinity, alignment: .leading)
        statusPillView(text: pill, color: pillColor)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

func captionView(_ s: String) -> some View {
    Text(s)
        .font(.custom("Outfit", size: 10))
        .tracking(0.4)
        .foregroundStyle(cMuted)
        .frame(maxWidth: .infinity, alignment: .center)
}

func modelView(_ s: String) -> some View {
    Text(s)
        .font(.custom("Outfit", size: 10))
        .tracking(0.55)
        .foregroundStyle(cMuted)
        .frame(maxWidth: .infinity, alignment: .center)
}

// Section head: accent tick + uppercase label, hairline rule running to the
// right edge (data-dashboard section treatment), 16/8 vertical rhythm.
func sectionHead(_ title: String) -> some View {
    HStack(spacing: 8) {
        headView(title)
        Rectangle()
            .fill(cBorder.opacity(0.55))
            .frame(height: 1)
    }
    .padding(.top, 16)
    .padding(.bottom, 8)
}

// Server base-URL editor: the same capsule language as the pills/buttons, in SF Mono
// like every value on the card. Return or Apply commits (normalize + persist +
// repoint the poller); while typing, the poller keeps the last committed URL.
func urlFieldView() -> some View {
    return VStack(spacing: 6) {
        HStack(spacing: 8) {
            TextField("http://192.168.1.13", text: Binding(
                get: { strata.urlText },
                set: { strata.urlText = $0 }
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(cStrong)
            .textFieldStyle(.plain)
            .autocorrectionDisabled(true)
            .onSubmit { commitURL() }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Capsule()
                .fill(cSurface.opacity(0.85))
                .stroke(strata.urlError != nil ? cRed.opacity(0.5) : cBorder.opacity(0.55), lineWidth: 1))
            ControlButton(label: "Apply", color: cBlue, action: commitURL)
        }
        captionView(strata.urlError ?? "\(hostLabel()) · metrics :\(metricsPort) · control :\(controlPort)")
    }
}

// JSX `cpu_name.replace(/\s*\d+-Core Processor/, "")` — strip the suffix and
// the digits/space that precede it.
func stripCore(_ s: String) -> String {
    guard let rng = s.range(of: "-Core Processor") else { return s }
    let head = s[..<rng.lowerBound]
    var end = head.endIndex
    while end > head.startIndex {
        let prev = head.index(before: end)
        let ch = head[prev]
        if ch == " " || (ch >= "0" && ch <= "9") { end = prev } else { break }
    }
    return String(head[..<end]) + String(s[rng.upperBound...])
}

// Scale helpers for GiB conversion and hit-rate percent (nulls stay nulls).
func scale1(_ v: Double?, by f: Double) -> Double? {
    guard let v else { return nil }
    return v * f
}

func scaleArr(_ a: [Double?]?, by f: Double) -> [Double?] {
    guard let a else { return [] }
    return a.map { (v) -> Double? in
        guard let v else { return nil }
        return v * f
    }
}

// MARK: - Down / starting branch (JSX: no parse → red pill or amber spinner)

func downBody() -> some View {
    let now = nowMs()
    let startTs = strata.startTsMs ?? 0
    let starting = strata.startTsMs != nil && now - startTs < 180_000
    let el = Int((Double(now - startTs) / 1000).rounded())
    let dc = starting ? cAmber : cRed
    let pillText = starting
        ? "\(spinnerGlyphs[strata.spinFrame % 10]) starting \(el)s"
        : "● server down"
    return VStack(spacing: 0) {
        tabPillsRow()
        headerRow(pillText, dc)
        VStack(spacing: 10) {
            captionView(starting ? "waiting for server to answer…" : "\(hostLabel()):\(metricsPort) unreachable")
            HStack(spacing: 10) {
                ControlButton(label: "Start Gyro-M", color: cBlue, action: {
                    strata.startTsMs = nowMs() // press arms the spinner…
                    runControl(startGyroMURL()) // …and fires the GET, fire-and-forget
                })
                ControlButton(label: "Start Coder", color: cBlue, action: {
                    strata.startTsMs = nowMs() // press arms the spinner…
                    runControl(startCoderURL()) // …and fires the GET, fire-and-forget
                })
            }
            // While the server is unreachable, the Server tab still lets you fix the host.
            if strata.tab == "server" { urlFieldView().padding(.top, 12) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

// MARK: - Server tab (JSX: green ● running, model · control, Stop only)

func serverBody(_ m: MetricsPayload) -> some View {
    return VStack(spacing: 0) {
        tabPillsRow()
        headerRow("● running", cGreen)
        captionView("\(m.engine?.model ?? "") · \(hostLabel()) · control :\(controlPort)")
            .padding(.top, 8)
        HStack(spacing: 10) {
            // Offer the *other* engine: a coder model up → start Gyro-M, and vice versa.
            if ((m.engine?.model ?? "").lowercased().contains("coder")) {
                ControlButton(label: "Start Gyro-M", color: cBlue, action: { runControl(startGyroMURL()) })
            } else {
                ControlButton(label: "Start Coder", color: cBlue, action: { runControl(startCoderURL()) })
            }
            ControlButton(label: "Stop", color: cRed, action: { runControl(stopURL()) })
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        sectionHead("Server URL")
        urlFieldView()
            .padding(.bottom, 4)
    }
}

// MARK: - Metrics tab — math ported verbatim from index.jsx

func metricsBody(_ m: MetricsPayload) -> some View {
    let eng = m.engine
    let live = m.live
    let hw = m.hardware
    let st = m.hardware_static
    let h = m.history
    let reqs = m.requests ?? []

    // JSX: reading = /read/i.test(phase); idle = !phase || /idle|sleep/.
    let phase = live?.phase
    let reading = (phase?.lowercased() ?? "").contains("read")
    let combined = ("\(phase ?? "") \(live?.state ?? "")").lowercased()
    let idle = phase == nil || combined.contains("idle") || combined.contains("sleep")

    // ppct = pr != null && pt ? pr/pt*100 : null
    let pr = live?.prompt_read
    let pt = live?.prompt_total
    var ppct: Double? = nil
    if let pr, let pt, pt != 0 { ppct = pr / pt * 100 }

    // rate = elapsed_s>0 && pr ? pr/elapsed_s : prefill_tok_s_mean
    let prefillRate = live?.prefill_tok_s_mean ?? 0
    let elapsed = live?.elapsed_s ?? 0
    let rate: Double
    if let pr, pr != 0, elapsed > 0 { rate = pr / elapsed } else { rate = prefillRate }

    // eta = ppct != null && rate>0 ? max(0,(pt-pr)/rate) : null
    var eta: Double? = nil
    if ppct != nil, let pr, let pt, rate > 0 { eta = max(0, (pt - pr) / rate) }

    // gpct = max_tokens ? generated/max_tokens*100 : 0
    let maxTok = live?.max_tokens ?? 0
    let gpct = maxTok != 0 ? (live?.generated ?? 0) / maxTok * 100 : 0

    // reqs sorted by time; newest = max by time; ago = max(0, round(m.time - r.time))
    let r = reqs.max(by: { (a, b) in (a.time ?? 0) < (b.time ?? 0) })
    let ago = max(0, Int(((m.time ?? 0) - (r?.time ?? 0)).rounded()))

    // sc = idle ? green : amber; pill = ● {state||idle}{ +queued}
    let sc = idle ? cGreen : cAmber
    let q = live?.queued ?? 0
    let stateLabel = (live?.state ?? "").isEmpty ? "idle" : live?.state ?? ""

    // Pinned spark scales + utilization colors.
    let vramPct: Double = {
        guard let u = hw?.gpu_mem_used, let t = hw?.gpu_mem_total, t > 0 else { return 0 }
        return u / t * 100
    }()
    let ramPct: Double = {
        guard let u = hw?.ram_used, let t = hw?.ram_total, t > 0 else { return 0 }
        return u / t * 100
    }()

    // PCIe row only when history has non-null PCIe samples (JSX hasPcie).
    let pcieHist = h?.gpu_pcie_rx_mb ?? []
    let pcieVals = pcieHist.compactMap { $0 }

    let hwPrefill = hw?.prefill_tok_s_mean
    let prefillDiffers = hwPrefill != nil && abs(hwPrefill! - (live?.prefill_tok_s_mean ?? 0)) > 1

    let draftText: String
    if let r, let off = r.drafts_offered, off != 0 {
        draftText = "\(fmtFixed((r.drafts_accepted ?? 0) / off * 100, digits: 0))% (\(fmtGrouped(r.drafts_accepted))/\(fmtGrouped(off)))"
    } else {
        draftText = "\u{2013}"
    }

    let gpuName = (st?.gpu_name ?? "") + ((st?.gpu_count ?? 0) > 1 ? " ×\(fmtGrouped(st?.gpu_count))" : "")
    let cpuHead = "\(stripCore(st?.cpu_name ?? "")) · \(fmtGrouped(st?.cores))C/\(fmtGrouped(st?.threads))T"
    let reqHead = "Last request · \(r == nil ? "\u{2013}" : "\(ago)s ago · \(r?.finish ?? "")")"

    return VStack(spacing: 0) {
        tabPillsRow()
        headerRow("● \(stateLabel)\(q != 0 ? " +\(fmtGrouped(q))" : "")", sc)
            .padding(.bottom, 2)
        modelView(eng?.model ?? "")
            .padding(.top, 8)

        // Fixed 52px live slot — keeps the card height stable (JSX does the same).
        VStack(spacing: 0) {
            if reading {
                kvView(key: "Reading prompt", value: ppct != nil
                    ? "\(fmtGrouped(pr)) / \(fmtGrouped(pt)) (\(fmtFixed(ppct, digits: 0))%)"
                    : "\(fmtGrouped(live?.prompt_tokens)) tokens…")
                    .padding(.top, 4)
                if ppct != nil {
                    barView(pct: ppct!, color: cBlue)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                }
                kvView(key: "elapsed", value: "\(fmtFixed(live?.elapsed_s))s\(eta != nil ? " · ETA \(fmtFixed(eta, digits: 0))s" : "")")
                    .padding(.top, 4)
            } else if !idle {
                kvView(key: phase ?? "", value: "\(fmtGrouped(live?.generated)) / \(fmtGrouped(live?.max_tokens)) tok")
                    .padding(.top, 4)
                barView(pct: gpct, color: cGreen)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                kvView(key: "prompt / elapsed", value: "\(fmtGrouped(live?.prompt_tokens)) tok · \(fmtFixed(live?.elapsed_s))s")
                    .padding(.top, 4)
            }
        }
        .frame(height: 52, alignment: Alignment(horizontal: .center, vertical: .top))
        .padding(.top, 16)

        sectionHead("Speed")
        rowView(label: "Decode", value: "\(fmtFixed(live?.tok_s)) tok/s", data: h?.tok_s ?? [], lo: nil, hi: nil, color: cBlue)
            .padding(.top, 4)
        kvView(key: "Window (\(fmtFixed(live?.tok_s_window_s))s) · sampled", value: "\(fmtFixed(live?.tok_s)) · \(fmtFixed(hw?.tok_s)) tok/s")
            .padding(.top, 4)
        kvView(key: "Decode mean", value: "\(fmtFixed(live?.tok_s_mean)) / \(fmtFixed(hw?.tok_s_mean)) tok/s")
            .padding(.top, 4)
        kvView(key: "Prefill mean", value: "\(fmtFixed(live?.prefill_tok_s_mean, digits: 0)) tok/s\(prefillDiffers ? " · hist \(fmtFixed(hwPrefill, digits: 0))" : "")")
            .padding(.top, 4)

        sectionHead(gpuName)
        rowView(label: "GPU", value: "\(fmtFixed(hw?.gpu_util, digits: 0))%", data: h?.gpu_util ?? [], lo: 0, hi: 100)
            .padding(.top, 4)
        rowView(label: "VRAM", value: "\(fmtFixed(scale1(hw?.gpu_mem_used, by: 1.0 / GiB))) / \(fmtFixed(scale1(hw?.gpu_mem_total, by: 1.0 / GiB))) GiB",
                data: scaleArr(h?.gpu_mem_used, by: 1.0 / GiB), lo: 0, hi: scale1(hw?.gpu_mem_total, by: 1.0 / GiB),
                color: utilColor(vramPct))
            .padding(.top, 4)
        rowView(label: "Temp", value: "\(fmtFixed(hw?.gpu_temp, digits: 0)) °C", data: h?.gpu_temp ?? [], lo: nil, hi: nil, color: cOrange)
            .padding(.top, 4)
        rowView(label: "Power", value: "\(fmtFixed(hw?.gpu_power, digits: 0)) / \(fmtFixed(hw?.gpu_power_limit, digits: 0)) W",
                data: h?.gpu_power ?? [], lo: 0, hi: hw?.gpu_power_limit, color: cPurple)
            .padding(.top, 4)
        if !pcieVals.isEmpty {
            rowView(label: "PCIe", value: "\(fmtFixed(pcieVals.last, digits: 0)) MB/s", data: pcieHist, lo: nil, hi: nil)
                .padding(.top, 4)
        }

        sectionHead(cpuHead)
        rowView(label: "CPU", value: "\(fmtFixed(hw?.cpu, digits: 0))%", data: h?.cpu ?? [], lo: 0, hi: 100, color: utilColor(hw?.cpu ?? 0))
            .padding(.top, 4)
        rowView(label: "RAM", value: "\(fmtFixed(scale1(hw?.ram_used, by: 1.0 / GiB))) / \(fmtFixed(scale1(hw?.ram_total, by: 1.0 / GiB))) GiB",
                data: scaleArr(h?.ram_used, by: 1.0 / GiB), lo: 0, hi: scale1(hw?.ram_total, by: 1.0 / GiB),
                color: utilColor(ramPct))
            .padding(.top, 4)
        rowView(label: "Disk R", value: "\(fmtFixed(hw?.disk_read_mb)) MB/s", data: h?.disk_read_mb ?? [], lo: 0, hi: nil)
            .padding(.top, 4)
        rowView(label: "Disk W", value: "\(fmtFixed(hw?.disk_write_mb)) MB/s", data: [], lo: 0, hi: nil)
            .padding(.top, 4)

        sectionHead(reqHead)
        kvView(key: "Decode", value: r != nil ? "\(fmtFixed(r?.decode_tok_s)) tok/s · \(fmtGrouped(r?.output_tokens)) tok" : "\u{2013}")
            .padding(.top, 4)
        kvView(key: "Expert cache hit", value: r?.hit_rate != nil ? "\(fmtFixed(scale1(r?.hit_rate, by: 100), digits: 1))%" : "\u{2013}")
            .padding(.top, 4)
        kvView(key: "Draft acceptance", value: draftText)
            .padding(.top, 4)
        kvView(key: "Prompt", value: r != nil ? "\(fmtGrouped(r?.prompt_tokens)) tok · \(fmtFixed(scale1(r?.prompt_ms, by: 0.001)))s · reused \(fmtGrouped(r?.reused))" : "\u{2013}")
            .padding(.top, 4)

        dividerView()
            .padding(.top, 16)
        HStack {
            Text("ctx \(fmtGrouped(eng?.context)) · kv \(eng?.kv?.display ?? "")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(cDim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("VRAM free \(fmtGrouped(eng?.vram_free_mib)) MiB · v\(eng?.version?.display ?? "")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(cDim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 8)
    }
}

// MARK: - Card (JSX container: 18px radius, 165° gradient, white@.10 stroke)

struct StrataCard: View {
    var body: some View {
        ZStack(alignment: Alignment(horizontal: .center, vertical: .top)) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.linearGradient(colors: [
                    hex("#161a1d").opacity(0.94), // st-surface
                    hex("#0e1113").opacity(0.96), // st-bg (OLED-dark)
                ], startPoint: UnitPoint(x: 0.37, y: 0.06), endPoint: UnitPoint(x: 0.63, y: 0.94)))
                .stroke(cBorder.opacity(0.55), lineWidth: 1)
            VStack(spacing: 0) {
                if let m = strata.payload {
                    if strata.tab == "server" {
                        serverBody(m)
                    } else {
                        metricsBody(m)
                    }
                } else {
                    downBody()
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Entry point (verified stub wiring; poller boots with the struct)

@main struct StrataWidget: App {
    private var _boot: Void = startPolling()

    var body: some Scene {
        Window("Strata", id: "strata.card.v5") { // fresh identity: clears the clipped persisted placement
            StrataCard()
        }
        .windowStyle(.hiddenTitleBar)
        .windowIdealPlacement { _, _ in
            WindowPlacement(x: 140, y: 30, width: 350, height: 640)
        }
    }
}
