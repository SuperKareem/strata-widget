import SwiftUI
import Foundation
import AppKit

// MARK: - Endpoints (JSX CMD + the control server)
// Not hardcoded: the Server tab edits one base URL (`scheme://host`), persisted in
// UserDefaults, and every endpoint is derived from it. Metrics and control ports
// are editable too (defaults 8080 / 8090), persisted per-port. The URL field
// accepts `127.0.0.1`, `http://host` or a full
// `http://host:8080/metrics`; the scheme/host is kept, path and port are replaced.

// Own suite, so the value lands in ~/Library/Preferences/com.strata.widget.plist
// rather than the global domain (this binary has no bundle identifier).
// `--instance=<id>` names this launch: parallel instances get their own suite
// and their own window frame autosave name, so two widgets running at once never
// read/write the same persisted window state (the shared-key race crashed the
// second launch ~15s after start). "default" keeps the historical suite name,
// so existing saved URLs/ports survive.
func parseInstance() -> String {
    for arg in CommandLine.arguments where arg.hasPrefix("--instance=") {
        let id = String(arg.dropFirst("--instance=".count))
        if !id.isEmpty { return id }
    }
    return "default"
}

let strataInstance = parseInstance()
let strataSuiteName = strataInstance == "default" ? "com.strata.widget" : "com.strata.widget.\(strataInstance)"
// Per-instance window autosave name → per-instance "NSWindow Frame …" key. The
// "default" instance keeps the historical id, so a position saved by the old SwiftUI
// window scene is restored by the AppKit window too; only its position is honored —
// the sizes saved back then were a title bar's height and a fixed card, and the
// card's size is ours to persist now (cardSizeKey). Parallel launches never
// read/write the same persisted window state (the shared-key race crashed the second
// launch ~15s after start).
let strataWindowAutosaveName = strataInstance == "default" ? "strata.card.v5" : "strata.card.v5.\(strataInstance)"
let strataDefaults = UserDefaults(suiteName: strataSuiteName)!
let baseURLKey = "strata.baseURL"
let defaultBaseURL = "http://127.0.0.1"
let defaultMetricsPort = 8080
let defaultControlPort = 8090

// The server's --api-key, sent as Authorization: Bearer on every request. Not a
// security boundary — see README. Empty means "no auth": the header is omitted.
// The built-in default stays "strata" so existing launches need no new flag.
let apiKeyKey = "strata.apiKey"
let defaultApiKey = "strata"

// Parse the launch flags so the widget can be pointed at a host/ports from the
// command line, e.g.
//   open StrataWidget --server-url=127.0.0.1 --strata-port=8080 --control-port=8090
// CLI values override UserDefaults (which overrides the built-in defaults).
// Only the keys that are actually present are returned (nil = not passed).
func parseServerArgs() -> (baseURL: String?, metricsPort: Int?, controlPort: Int?, apiKey: String?) {
    var base: String? = nil
    var metrics: Int? = nil
    var control: Int? = nil
    var key: String? = nil
    for arg in CommandLine.arguments {
        if arg.hasPrefix("--server-url=") {
            base = String(arg.dropFirst("--server-url=".count))
        } else if arg.hasPrefix("--strata-port=") {
            metrics = Int(arg.dropFirst("--strata-port=".count))
        } else if arg.hasPrefix("--control-port=") {
            control = Int(arg.dropFirst("--control-port=".count))
        } else if arg.hasPrefix("--api-key=") {
            // Present-but-empty (--api-key=) is a deliberate "no auth", so this
            // stays nil-differentiated from "flag not passed".
            key = String(arg.dropFirst("--api-key=".count))
        }
    }
    return (base, metrics, control, key)
}

// nil when the text can't name a host; the caller keeps the draft visible instead.
func normalizeBase(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    let lowered = s.lowercased()
    if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") { s = "http://" + s }
    guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
    c.path = "" // endpoints append their own path
    c.port = nil // ports are editable via the port fields below
    c.query = nil
    c.fragment = nil
    return c.url?.absoluteString
}

// Bare hosts from CLI flags / stored values: "--server-url=192.168.1.20" must
// become a real URL, otherwise URLComponents yields "//:8080/metrics" and curl
// refuses it, so the card reads "server down" against a live server.
func configuredBaseURL() -> String {
    let raw = parseServerArgs().baseURL ?? strataDefaults.string(forKey: baseURLKey) ?? defaultBaseURL
    return normalizeBase(raw) ?? defaultBaseURL
}

func endpoint(_ path: String, port: Int) -> String? {
    guard var c = URLComponents(string: strata.baseURL) else { return nil }
    c.path = path
    c.port = port
    return c.url?.absoluteString
}

func metricsURL() -> String? { endpoint("/metrics", port: strata.metricsPort) }
func controlURL(_ cmd: String) -> String? { endpoint("/\(cmd)", port: strata.controlPort) }
func stopURL() -> String? { controlURL("stop") }
func modelsURL() -> String? { endpoint("/models", port: strata.controlPort) }

// Chat is Strata itself, not the control server: POST /v1/chat/completions with
// SSE streaming lives on the metrics port (the same :8080 as /metrics), and the
// chat footer reads /health there. Verified live: `Bearer strata` → 200; the
// web app at :8080 uses this exact endpoint. See chat.swift for the transport.
func chatURL() -> String? { endpoint("/v1/chat/completions", port: strata.metricsPort) }
func healthURL() -> String? { endpoint("/health", port: strata.metricsPort) }

// GET /models on the control port: the server answers with the models it has
// loaded and, for each one, the endpoint that launches it.
struct ModelsPayload: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: String
        let state: String?
        let endpoint: String
    }
    let ok: Bool?
    let models: [Entry]?
}

// Launch URL for one entry: the server supplies the path, so the widget never
// guesses it. Paths arrive with a leading slash already.
func launchURL(_ entry: ModelsPayload.Entry) -> String? {
    let path = entry.endpoint.hasPrefix("/") ? entry.endpoint : "/" + entry.endpoint
    return endpoint(path, port: strata.controlPort)
}

// Host-only view of the base URL for captions ("127.0.0.1:8080 unreachable").
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
// spawn a child process.) The bearer key comes from strata.apiKey (CLI / dialog /
// UserDefaults). Verified live: `Bearer strata` → 200 on :8080/metrics, missing
// key → 401. curl -m 3 mirrors the JSX timeout.

func fetchBody(_ url: String?) async -> String? {
    guard let url, let target = URL(string: url) else { return nil }
    // Per-endpoint temp file (port+path+pid): polls never race each other.
    let name = String(target.path.map { c in (c.isLetter || c.isNumber) ? c : "-" }) // "/metrics" → "-metrics-"
    let tmp = "/tmp/strata-fetch-\(target.port ?? 0)-\(name)-\(getpid()).json"
    defer { _ = remove(tmp) } // unlink after the read below
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var args = ["-s", "-m", "3"]
    // An empty key means "this server needs no auth"; sending `Bearer ` with an
    // empty token is worse than sending nothing (Strata answers 401 for it).
    if !strata.apiKey.isEmpty {
        args += ["-H", "Authorization: Bearer \(strata.apiKey)"]
    }
    args += ["-o", tmp, url]
    curl.arguments = args
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
    var models: ModelsPayload? = nil
    var tab = "metrics"
    // Mini mode: double-clicking the card collapses it to just the header,
    // model and Speed section (see miniBody). Toggling it resizes the card window.
    var mini = false
    // Persisted server base URL; urlText is the field's live draft, so typing
    // mid-edit never repoints the poller.
    // CLI flags (parseServerArgs) override UserDefaults, which overrides the
    // built-in defaults. CLI wins so each alias can point at its own server.
    var baseURL: String = configuredBaseURL()
    var urlText: String = configuredBaseURL()
    var urlError: String? = nil
    // Ports are editable now (were hardcoded). Draft text lets the user type
    // without repointing the poller until they commit.
    var metricsPort: Int = {
        if let p = parseServerArgs().metricsPort, (1..<65536).contains(p) { return p }
        let v = strataDefaults.integer(forKey: "strata.metricsPort")
        return v == 0 ? defaultMetricsPort : v
    }()
    var controlPort: Int = {
        if let p = parseServerArgs().controlPort, (1..<65536).contains(p) { return p }
        let v = strataDefaults.integer(forKey: "strata.controlPort")
        return v == 0 ? defaultControlPort : v
    }()
    var metricsPortText: String = parseServerArgs().metricsPort.map(String.init) ?? String(defaultMetricsPort)
    var controlPortText: String = parseServerArgs().controlPort.map(String.init) ?? String(defaultControlPort)
    var portError: String? = nil
    // Bearer key. Same precedence as the URL/ports: CLI → UserDefaults → default.
    // apiKeyText is the dialog's live draft; the header uses `apiKey` only.
    var apiKey: String = parseServerArgs().apiKey ?? strataDefaults.string(forKey: apiKeyKey) ?? defaultApiKey
    var apiKeyText: String = parseServerArgs().apiKey ?? strataDefaults.string(forKey: apiKeyKey) ?? defaultApiKey
    // Model whose Launch was pressed and is still loading. Loading a model
    // restarts the engine, so /metrics goes down then comes back up; the spinner
    // clears the moment metrics returns (launchSawDown flips while it is nil), so
    // it never hangs on a name that does not exactly match the launched id. The
    // name-match path covers a hot-swap with no downtime, and launchStartMs caps
    // a silent failure so the button becomes pressable again.
    var launchingId: String? = nil
    var launchStartMs = 0
    var launchSawDown = false
}
let strata = StrataState()

// Which tab body the card renders, as one string. Read inside StrataCard's body, so
// SwiftUI observes both `payload` and `tab`; a single value means one `.animation`
// drives every content swap (tab click, server up, server down).
var strataBodyKey: String { strata.payload == nil ? "down" : strata.tab }

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
        strata.launchingId = nil
    }
}

// Commit the port drafts (Return / Apply): validate 1..<65536, persist, and
// repoint the poller + control endpoints at the new ports.
func commitPorts() {
    var changed = false
    if let p = Int(strata.metricsPortText), (1..<65536).contains(p) {
        if p != strata.metricsPort { strata.metricsPort = p; changed = true }
        strataDefaults.set(p, forKey: "strata.metricsPort")
    } else { strata.portError = "bad metrics port" }
    if let p = Int(strata.controlPortText), (1..<65536).contains(p) {
        if p != strata.controlPort { strata.controlPort = p; changed = true }
        strataDefaults.set(p, forKey: "strata.controlPort")
    } else { strata.portError = "bad control port" }
    if changed { strata.payload = nil; strata.launchingId = nil }
}

// Commit the key draft (Save / Return): persist and re-poll, since a wrong key
// yields 401 rather than a parse failure, so the card would otherwise keep
// showing the stale payload from the key that happened to work at launch.
func commitApiKey() {
    let key = strata.apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
    if key != strata.apiKey {
        strata.apiKey = key
        strataDefaults.set(key, forKey: apiKeyKey)
        strata.payload = nil
        strata.launchingId = nil
    }
}

// The poller replaces refreshFrequency=1000 + curl -m 3: one long-running Task
// loop, decode, assign, sleep 1s. Spawned once when the app struct initializes.
func startPolling() {
    Task {
        var tick = 0
        while !Task.isCancelled {
            var parsed: MetricsPayload? = nil
            if let url = metricsURL(), let body = await fetchBody(url) {
                parsed = try? JSONDecoder().decode(MetricsPayload.self, from: Data(body.utf8))
            }
            strata.payload = parsed
            // /models changes only when the server loads a model, so it is
            // refetched every 5s instead of every poll.
            if tick % 5 == 0 {
                var fetched: ModelsPayload? = nil
                if let url = modelsURL(), let body = await fetchBody(url) {
                    fetched = try? JSONDecoder().decode(ModelsPayload.self, from: Data(body.utf8))
                }
                if fetched != nil { strata.models = fetched }
            }
            // Loading a model bounces the engine: while metrics is down we mark
            // launchSawDown, and when it answers again the launch is done. A
            // name-match clears a no-downtime hot-swap, and 180s caps a launch
            // that never lands so the button is pressable again.
            if let id = strata.launchingId {
                if parsed == nil { strata.launchSawDown = true }
                else if strata.launchSawDown || isRunningModel(id) { strata.launchingId = nil }
                if strata.launchingId != nil && nowMs() - strata.launchStartMs > 180_000 {
                    strata.launchingId = nil
                }
            }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - Small view helpers

// Lives in StrataCard rather than in each tab body: hoisting it keeps the pill row
// the same view across a tab switch, so only the content below cross-fades and the
// pills animate their own active state instead of fading out and back in.
func tabPillsRow() -> some View {
    HStack(spacing: 6) {
        pillView(text: "Metrics", active: strata.tab == "metrics")
            .onTapGesture { strata.tab = "metrics" }
            .pointerCursor()
        pillView(text: "Server", active: strata.tab == "server")
            .onTapGesture { strata.tab = "server" }
            .pointerCursor()
        // The card window never takes keyboard, so the chat is the widget's
        // second window (chat.swift): this pill just opens/toggles it.
        pillView(text: "Chat", active: chatWindowVisible)
            .onTapGesture { toggleChatWindow() }
            .pointerCursor()
    }
    .padding(.top, 10)
    .padding(.bottom, 8)
}

func headerRow(_ pill: String, _ pillColor: Color) -> some View {
    HStack {
        // Named instances show their id so parallel cards are distinguishable.
        Text(strataInstance == "default" ? "Strata" : "Strata · \(strataInstance)")
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

// Server editor dialog: the base-URL field, the bearer key, and the metrics/control
// ports, with Save (commit + close) and Cancel (close, keep last committed values).
// Shown in its own window via openServerDialog() so the fields can capture keyboard.
// The URL field is bound to @FocusState via a token, so opening the window hands
// keyboard focus to it (the card's hidden-title-bar window never did).
struct ServerDialogView: View {
    @FocusState private var focusURL: Bool
    @FocusState private var focusKey: Bool
    @FocusState private var focusMetrics: Bool
    @FocusState private var focusControl: Bool

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("SERVER URL".uppercased())
                    .font(.system(size: 8, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(cMuted)
                TextField("http://127.0.0.1", text: Binding(
                    get: { strata.urlText },
                    set: { strata.urlText = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(cStrong)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color(cSurface).opacity(0.85))
                .overlay(fieldStroke(focused: focusURL))
                .animation(motion, value: focusURL)
                .focused($focusURL)
            }
            apiKeyRowView(focusKey: $focusKey)
            portRowView(focusMetrics: $focusMetrics, focusControl: $focusControl)
            HStack(spacing: 8) {
                ControlButton(label: "Cancel", color: cMuted, action: { closeServerDialog() })
                ControlButton(label: "Save", color: cBlue, action: {
                    commitURL()
                    commitApiKey()
                    commitPorts()
                    closeServerDialog()
                })
            }
        }
        .padding(20)
        // The window is key by the time this fires; a short delay lets the
        // field become first responder so typing works immediately on open.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusURL = true
            }
        }
    }
}

// Hide the editor window and hand key status back to the card. Called by the
// dialog's Cancel / Save buttons.
//
// The window is hidden, not closed: its NSHostingController stays alive for the next
// open. Releasing a hosting controller whose view is still attached to a window (or
// mid-click) corrupts the main thread's autorelease pool, which shows up as an
// objc_release SIGSEGV when the run loop later drains it — exactly the crash seen
// when Save/Cancel closes the widget.
func closeServerDialog() {
    serverDialogWindow?.orderOut(nil)
    // The card may have lost key status while the editor was open; bring it back.
    cardWindow?.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
}

// Open the server editor in its own normal window. The card window uses a hidden
// title bar and does not capture keyboard, so the text fields need a real window
// that becomes key and hands focus to the first field. The window is created once
// and reused (see closeServerDialog) so its SwiftUI tree is never torn down.
var serverDialogWindow: NSWindow? = nil

func openServerDialog() {
    if let existing = serverDialogWindow {
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let window = NSWindow()
    let hosting = NSHostingController(rootView: ServerDialogView())
    window.contentViewController = hosting
    window.styleMask = [.titled, .closable]
    window.title = "Strata · Server"
    window.setContentSize(NSSize(width: 360, height: 312))
    window.center()
    window.level = .normal
    window.makeKeyAndOrderFront(nil)
    serverDialogWindow = window
    // Activate the app so the editor becomes key; the URL field's @FocusState
    // fires via .onAppear and typing works immediately on open.
    NSApp.activate(ignoringOtherApps: true)
}

// Visible keyboard-focus state for the capsule fields: the hairline stroke
// brightens to st-accent and thickens by half a pixel. The design system's Ring
// token is #FFFFFF, which would be a white halo on an already-light ink text;
// the accent reads as the same "active" signal the pills use, at higher
// contrast than the idle st-line stroke.
func fieldStroke(focused: Bool) -> some View {
    Capsule()
        .stroke(focused ? cBlue.opacity(0.75) : cBorder.opacity(0.55),
                lineWidth: focused ? 1.5 : 1)
}

// A single labeled port field: small uppercase key above a monospaced capsule.
// Focus lives in the dialog and arrives as a binding so Tab moves between fields;
// the field owns its own visible ring, which needs a View struct to observe it.
struct PortField: View {
    let label: String
    let text: Binding<String>
    var placeholder: String = "8080"
    @FocusState.Binding var focused: Bool
    let commit: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 8, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(cMuted)
            TextField(placeholder, text: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(cStrong)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .onSubmit { commit() }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color(cSurface).opacity(0.85))
                .overlay(fieldStroke(focused: focused))
                .animation(motion, value: focused)
                .focused($focused)
        }
        .frame(maxWidth: .infinity)
    }
}

// The bearer key field, mirroring the URL field's capsule treatment. Plain text,
// not a SecureField: on a LAN the key is not a secret worth hiding, and being able
// to read it back is what makes a 401 debuggable.
func apiKeyRowView(focusKey: FocusState<Bool>.Binding) -> some View {
    return VStack(spacing: 6) {
        Text("API KEY".uppercased())
            .font(.system(size: 8, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(cMuted)
        TextField("strata", text: Binding(
            get: { strata.apiKeyText },
            set: { strata.apiKeyText = $0 }
        ))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(cStrong)
        .textFieldStyle(.plain)
        .autocorrectionDisabled(true)
        .submitLabel(.done)
        .onSubmit { commitApiKey() }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(cSurface).opacity(0.85))
        .overlay(fieldStroke(focused: focusKey.wrappedValue))
        .animation(motion, value: focusKey.wrappedValue)
        .focused(focusKey)
    }
}

// Two port fields (metrics / control) alongside the base-URL field.
func portRowView(focusMetrics: FocusState<Bool>.Binding,
                 focusControl: FocusState<Bool>.Binding) -> some View {
    return HStack(spacing: 8) {
        PortField(label: "metrics",
                  text: Binding(get: { strata.metricsPortText },
                                set: { strata.metricsPortText = $0 }),
                  focused: focusMetrics,
                  commit: commitPorts)
        PortField(label: "control",
                  text: Binding(get: { strata.controlPortText },
                                set: { strata.controlPortText = $0 }),
                  focused: focusControl,
                  commit: commitPorts)
    }
}

// Read-only ports for the Server tab: shows the live (committed) metrics and
// control ports, matching the capsule treatment of the other server rows.
func portsRowView() -> some View {
    return HStack(spacing: 8) {
        portCapsule("metrics", "\(strata.metricsPort)")
        portCapsule("control", "\(strata.controlPort)")
    }
}

// One model per row, straight from GET /models: the id plus a Launch button that
// calls the endpoint the server named for that model. The row for the model the
// engine is already running has no button, since launching it would restart it.
func modelsListView() -> some View {
    let entries = strata.models?.models ?? []
    if entries.isEmpty {
        return AnyView(captionView(strata.models == nil ? "models not reported yet" : "no models reported")
            .padding(.vertical, 6))
    }
    return AnyView(
        VStack(spacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                modelRowView(e)
            }
        }
    )
}

func modelRowView(_ e: ModelsPayload.Entry) -> some View {
    let running = isRunningModel(e.id)
    return HStack(spacing: 8) {
        Text(e.id)
            .font(.custom("Outfit", size: 11)).fontWeight(.semibold)
            .tracking(0.4)
            .foregroundStyle(cStrong)
            .lineLimit(1)
        Spacer(minLength: 8)
        if !running {
            ControlButton(label: "Launch", color: cBlue, loading: strata.launchingId == e.id, action: {
                strata.launchingId = e.id // arm this row's spinner…
                strata.launchStartMs = nowMs()
                strata.launchSawDown = false
                runControl(launchURL(e)) // …and fire the GET, fire-and-forget
            })
        }
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 10)
    .background(Capsule().fill(Color(cSurface).opacity(0.5)))
    .overlay(Capsule().stroke(cBorder.opacity(0.55), lineWidth: 1))
}

// The model id the metrics payload reports as loaded, nil while the server is down.
func runningModel() -> String? {
    let m = strata.payload?.engine?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (m?.isEmpty == false) ? m : nil
}

// /models names entries after the weight file ("gyro-Gyro-M") while metrics reports
// the engine's short name ("gyro-m"), so equality never matches. Split both into
// alphanumeric tokens and treat the entry as running when it covers every token of
// the loaded name.
func isRunningModel(_ id: String) -> Bool {
    guard let running = runningModel() else { return false }
    func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
    let want = tokens(running)
    return !want.isEmpty && want.isSubset(of: tokens(id))
}

func portCapsule(_ label: String, _ value: String) -> some View {
    return HStack(spacing: 6) {
        Text(label.uppercased())
            .font(.system(size: 8, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(cMuted)
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(cStrong)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Capsule().fill(Color.clear))
    .overlay(Capsule().stroke(cBorder.opacity(0.55), lineWidth: 1))
}

// The server URL shown as a capsule button with a transparent background. It
// renders the live (committed) URL; clicking does nothing — the URL is edited
// through the "Change Server" flow, not from here. Kept as a Button for layout
// parity with the other capsule controls.
func serverURLButton() -> some View {
    return Button(strata.baseURL) {
        // no-op: the URL is edited through the "Change Server" flow
    }
    .buttonStyle(.plain)
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(cStrong)
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Capsule().fill(Color.clear))
    .overlay(Capsule().stroke(cBorder.opacity(0.55), lineWidth: 1))
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

// Entry point for the server editor. openServerDialog() was previously defined
// but never called, so the URL/port fields — and their focus behaviour — were
// unreachable from the widget. Same ghost-pill treatment as the other controls.
func changeServerButton() -> some View {
    return HStack(spacing: 10) {
        ControlButton(label: "Change server", color: cMuted, action: { openServerDialog() })
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
}

// MARK: - Down / starting branch (JSX: no parse → red pill or amber spinner)

func downBody() -> some View {
    return VStack(spacing: 0) {
        headerRow("● server down", cRed)
        VStack(spacing: 10) {
            captionView("\(hostLabel()):\(strata.metricsPort) unreachable")
            sectionHead("Models")
            modelsListView()
            // While the server is unreachable, the Server tab still shows the URL.
            if strata.tab == "server" {
                serverURLButton()
                changeServerButton()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}

// MARK: - Server tab (JSX: green ● running, model · control, Stop only)

func serverBody(_ m: MetricsPayload) -> some View {
    return VStack(spacing: 0) {
        headerRow("● running", cGreen)
        captionView("\(m.engine?.model ?? "") · \(hostLabel()) · control :\(strata.controlPort)")
            .padding(.top, 8)
        HStack(spacing: 10) {
            ControlButton(label: "Stop", color: cRed, action: { runControl(stopURL()) })
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        sectionHead("Models")
        modelsListView()
        sectionHead("Server URL")
        serverURLButton()
        changeServerButton()
        sectionHead("Ports")
        portsRowView()
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

// MARK: - Card (JSX container: 16px radius, 165° frosted gradient, white@.10 stroke)

// The card IS the window: no title bar, no traffic lights, no window background
// behind it, so the rounded card is flush with the window edge and the shadow
// follows the card.
//
// This used to be a SwiftUI `Window` scene whose styleMask was rewritten to a
// borderless one (drop `.titled`) after it mounted. That produced two crashes and
// never fully hid the chrome:
//   • AppKit's liquid-glass frame teardown left a stale entry in the view-hierarchy
//     lock, so the next layout pass threw `-[NSTaggedPointerString
//     _unlockViewHierarchyForWriting]` from
//     `-[NSView _layoutSubtreeIfNeededAndAllowTemporaryEngine:]`.
//   • Re-applying the borderless mask on every window update fought SwiftUI's own
//     content sizing and collapsed the window to 0x0 (invisible widget).
//   • A titled window keeps its glass hairline whatever `backgroundColor` says, so
//     the border the widget is supposed to not have stayed visible.
// A window AppKit creates borderless from the start has no frame to dismantle, none
// of that machinery is needed, and the size is ours to set.

// Was `WindowPlacement(x: 140, y: 30, width: 350, height: 640)` on the scene. 640
// clipped the metrics tab (the ctx/kV footer fell off the bottom edge), so the default
// grew to the content's own height at the design width; it is the starting size, not a
// limit — the corner grip resizes the card and the size survives relaunches.
let cardContentSize = NSSize(width: 350, height: 780)

// Inset from the top-left of the visible screen — a widget belongs to the corner you
// glance at. AppKit's window origin is bottom-left, so the y inset is measured down.
let cardDefaultInset = (x: 140.0, y: 30.0)

// Resizable, but still a card: never so narrow that the value columns truncate, never
// so tall that a widget covers the screen (maxHeight is also capped by the screen).
let cardMinSize = NSSize(width: 320, height: 560)
let cardMaxSize = NSSize(width: 720, height: 1400)

// The user's own size, persisted separately from AppKit's frame autosave: the autosave
// carries the position (and a size from whatever build last ran), while this key is
// written only when a grip drag resizes the card. Absent = the design size above.
let cardSizeKey = "strata.cardSize"

// Bottom-right hit area for the resize grip, in window points. The card draws a glyph
// of its own because a borderless window has no AppKit resize corners.
let cardResizeGrip: CGFloat = 18
// Collapsed card shown on double-click: only the header (title + status pill), the
// running model, and the Speed section. Anchored to the same top-left corner as the
// full card, so the widget shrinks downward from the corner you glance at. Bypasses
// clampCardSize on purpose — the full card's 320x560 minimum is far too tall here.
let miniCardSize = NSSize(width: 300, height: 250)

/// Resize the card window to mini or full around its top-left corner and update the
/// observed state so the SwiftUI card re-renders the matching body.
func setMiniMode(_ on: Bool) {
    strata.mini = on
    (cardWindow as? StrataWidgetWindow)?.setMini(on)
}

/// Double-click affordance: flip between the full card and the collapsed mini card.
func toggleMiniMode() { setMiniMode(!strata.mini) }

// Close affordance in the card's top-right corner. The card is the widget, so closing
// it ends the process exactly like the right-click Quit menu item (LSUIElement has no
// Dock icon to keep alive behind a hidden window).
func closeCardButton() -> some View {
    Button(action: { NSApp.terminate(nil) }) {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(cMuted)
            .frame(width: 16, height: 16)
            .background(Circle().fill(cSurface.opacity(0.7)))
            .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .pointerCursor()
    .help("Close widget")
}

// MARK: - Mini (collapsed) card body — header + model + Speed only.

// Mirrors the top of metricsBody's Speed block (index.jsx) so the numbers read exactly
// the same; only the idle/amber status and the four speed rows are needed here.
func miniBody(_ m: MetricsPayload) -> some View {
    let live = m.live
    let hw = m.hardware
    let eng = m.engine
    let h = m.history
    let combined = ("\(live?.phase ?? "") \(live?.state ?? "")").lowercased()
    let idle = live?.phase == nil || combined.contains("idle") || combined.contains("sleep")
    let sc = idle ? cGreen : cAmber
    let stateLabel = (live?.state ?? "").isEmpty ? "idle" : (live?.state ?? "")
    let q = live?.queued ?? 0
    return VStack(spacing: 0) {
        headerRow("● \(stateLabel)\(q != 0 ? " +\(fmtGrouped(q))" : "")", sc)
            .padding(.bottom, 2)
        modelView(eng?.model ?? "")
            .padding(.top, 8)
        sectionHead("Speed")
            .padding(.top, 12)
        rowView(label: "Decode", value: "\(fmtFixed(live?.tok_s)) tok/s", data: h?.tok_s ?? [], lo: nil, hi: nil, color: cBlue)
            .padding(.top, 4)
        kvView(key: "Window (\(fmtFixed(live?.tok_s_window_s))s) · sampled", value: "\(fmtFixed(live?.tok_s)) · \(fmtFixed(hw?.tok_s)) tok/s")
            .padding(.top, 4)
        kvView(key: "Decode mean", value: "\(fmtFixed(live?.tok_s_mean)) / \(fmtFixed(hw?.tok_s_mean)) tok/s")
            .padding(.top, 4)
        kvView(key: "Prefill mean", value: "\(fmtFixed(live?.prefill_tok_s_mean, digits: 0)) tok/s")
            .padding(.top, 4)
    }
}

func clampCardSize(_ size: NSSize) -> NSSize {
    let screenCap = NSScreen.main?.visibleFrame.height ?? cardMaxSize.height
    return NSSize(
        width: min(max(size.width, cardMinSize.width), cardMaxSize.width),
        height: min(max(size.height, cardMinSize.height), min(cardMaxSize.height, screenCap)))
}

/// The persisted card size, or the design size when nothing usable was stored.
func persistedCardSize() -> NSSize {
    guard let raw = strataDefaults.string(forKey: cardSizeKey) else { return cardContentSize }
    let parts = raw.split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2 else { return cardContentSize }
    return clampCardSize(NSSize(width: parts[0], height: parts[1]))
}

func saveCardSize(_ size: NSSize) {
    strataDefaults.set("\(Int(size.width.rounded()))x\(Int(size.height.rounded()))", forKey: cardSizeKey)
}

// A borderless window answers `canBecomeKeyWindow` with NO and AppKit exposes no
// setter for that. Without key status a click on the card never activates the app,
// so the pills only respond on the second click of every pair. A subclass is the
// only supported way to answer yes — and because the window is ours from the start,
// there is no runtime class swap (and no KVO-swizzled base class) to keep correct.
final class StrataWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Set by makeCardWindow; the window keeps it alive, so nothing else has to.
    var dragMover: WindowDragMover?

    // The window owns its content size. Everything that reaches setFrame is a
    // *placement* — the frame autosave and AppKit's deferred restore both rewrite the
    // size, and they re-apply late, late enough to undo a fix made right after
    // ordering, while autosaves written by older builds carry a title bar's height or a
    // stale fixed size. So the size is substituted here (clamped to the card's bounds),
    // and the top-left is pinned because a widget is anchored to a desktop corner while
    // AppKit pins the bottom-left: growing downward is what a taller card means.
    var cardSize = cardContentSize
    // When true the window is the collapsed mini card: setFrame substitutes
    // miniCardSize instead of the clamped full-card size. Toggled by setMini.
    var mini = false

    func setMini(_ on: Bool) {
        mini = on
        let current = frame
        let size = on ? miniCardSize : clampCardSize(cardSize)
        setFrame(NSRect(x: current.minX, y: current.maxY - size.height,
                        width: size.width, height: size.height), display: true)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let size = mini ? miniCardSize : clampCardSize(cardSize)
        super.setFrame(
            NSRect(x: frameRect.minX,
                   y: frameRect.maxY - size.height,
                   width: size.width,
                   height: size.height),
            display: flag)
    }

    /// Grow/shrink the card around its top-left corner, which is what dragging the
    /// bottom-right grip implies. Returns whether the size actually changed.
    @discardableResult
    func resizeCard(to size: NSSize) -> Bool {
        let next = clampCardSize(size)
        guard next != cardSize else { return false }
        cardSize = next
        let current = frame
        setFrame(NSRect(x: current.minX, y: current.maxY - next.height,
                        width: next.width, height: next.height), display: true)
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            dragMover?.handle(event)
        default:
            break
        }
        super.sendEvent(event) // the card still gets the click it was dragging through
    }
}

// The first click on an inactive widget would normally be spent on activating the
// app instead of reaching the pills. `acceptsFirstMouse` delivers it to SwiftUI.
final class StrataCardHostingView: NSHostingView<StrataCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Without a title bar there is no AppKit drag affordance, and
// `isMovableByWindowBackground` never fires because the hosted card handles mouse-downs
// itself instead of handing them to the window. Interposing `sendEvent(_:)` sees every
// mouse event before the content view gets it, so dragging anywhere on the card moves
// the window no matter what SwiftUI does with the click. A borderless window has no
// resize corners either, so the same interposition handles a drag that starts on the
// card's own bottom-right grip (ResizeGripView draws it).
//
// The mover adds its own movement threshold, which keeps taps on the pills and buttons
// exactly where they are: a click that jitters a few pixels must not nudge the widget.
final class WindowDragMover {
    // The card window subclass, not NSWindow: the resize path needs its own setter.
    private weak var window: StrataWidgetWindow?
    private var frameAtStart: NSRect?
    private var anchorAtStart: NSPoint?
    private var translationAtThreshold: NSPoint = .zero
    private enum Gesture { case none, move, resize }
    private var gesture = Gesture.none
    private var didResize = false
    private var cursorPushed = false
    private static let dragThreshold: CGFloat = 6

    init(_ window: StrataWidgetWindow) {
        self.window = window
    }

    /// A primary-button press on the bottom-right corner resizes; anywhere else moves.
    /// `locationInWindow` is in the window's own non-flipped coordinates, so the corner
    /// is the maximum x and the minimum y.
    private func gesture(for event: NSEvent, window: NSWindow) -> Gesture {
        let p = event.locationInWindow
        return (p.x >= window.frame.width - cardResizeGrip && p.y <= cardResizeGrip) ? .resize : .move
    }

    /// Called for the primary-button mouse events, ahead of `super.sendEvent`.
    /// Screen coordinates are bottom-left on both sides of the conversion, so no
    /// flipped-view adjustment is needed here.
    func handle(_ event: NSEvent) {
        guard let window else { return }
        switch event.type {
        case .leftMouseDown:
            gesture = self.gesture(for: event, window: window)
            translationAtThreshold = .zero
            frameAtStart = window.frame
            anchorAtStart = window.convertPoint(toScreen: event.locationInWindow)
        case .leftMouseDragged:
            guard let start = frameAtStart, let anchor = anchorAtStart, gesture != .none else { return }
            let now = window.convertPoint(toScreen: event.locationInWindow)
            let t = NSPoint(x: now.x - anchor.x, y: now.y - anchor.y)
            if gesture == .none { return }
            if translationAtThreshold == .zero {
                guard hypot(t.x, t.y) > Self.dragThreshold else { return }
                translationAtThreshold = t // don't jump by the threshold on the first real move
                setCursor(gesture)
            }
            // Both gestures are compensated so the pointer stays glued to whatever it
            // grabbed, and both keep the top-left corner where it is.
            let dx = t.x - translationAtThreshold.x
            let dy = t.y - translationAtThreshold.y
            if gesture == .move {
                window.setFrameOrigin(NSPoint(x: start.minX + dx, y: start.minY + dy))
            } else {
                // Screen y grows upward: moving the pointer down (dy < 0) lengthens the
                // card, since the top-left is fixed and the bottom edge follows.
                if window.resizeCard(to: NSSize(width: start.width + dx, height: start.height - dy)) {
                    didResize = true
                }
            }
        case .leftMouseUp:
            if didResize {
                saveCardSize(window.cardSize) // the size the user dragged to outlives the launch
            }
            restoreCursor()
            gesture = .none
            didResize = false
            frameAtStart = nil
            anchorAtStart = nil
        default:
            break
        }
    }

    // A drag that isn't AppKit's own gets no cursor of its own, so say what it does.
    private func setCursor(_ gesture: Gesture) {
        guard !cursorPushed else { return }
        // AppKit exposes no diagonal corner cursor (the resize ones are gone in macOS
        // 15), so the grip gets a crosshair: it says "adjust this edge" without lying.
        (gesture == .resize ? NSCursor.crosshair : NSCursor.closedHand).push()
        cursorPushed = true
    }

    private func restoreCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

// The card window: chrome-free (card only), draggable anywhere, on every Space,
// behind ordinary windows, unmoved by Space transitions, out of the Window menu.
var cardWindow: NSWindow? = nil

func makeCardWindow() {
    guard cardWindow == nil else { return }
    // The persisted/design size is in place before the autosave restores below, so the
    // restore only ever moves the card; StrataWidgetWindow.setFrame keeps this size.
    let cardSize = persistedCardSize()
    let window = StrataWidgetWindow(
        contentRect: NSRect(origin: .zero, size: cardSize),
        styleMask: [], // borderless: styleMask [] is what has no frame at all
        backing: .buffered,
        defer: true)
    window.cardSize = cardSize
    // The window governs the size; the card fills it. Left to its defaults, an
    // NSHostingView reports the hosted view's ideal size and AppKit re-fits the window
    // to that, which overrode the design size below and left the card at whatever the
    // old titled scene had saved.
    let hosting = StrataCardHostingView(rootView: StrataCard())
    hosting.sizingOptions = []
    // The card is drawn straight into the window: wrapping the hosting view in
    // `NSGlassEffectView` is not an option — the glass frosts whatever it embeds, so
    // wrapping the card blurs the card's own text instead of the desktop behind it.
    // The background blur comes from the glass layer inside the card's own view tree
    // (`cardSurface` in components.swift), which sits under the text.
    window.contentView = hosting
    window.title = "Strata" // never drawn (no title bar) but it is the Window-list identity
    window.backgroundColor = .clear // only the rounded card is drawn
    window.isOpaque = false
    window.hasShadow = true // follows the card, since the card is the whole window
    // One below normal (0): above the desktop picture and its icons, below every
    // ordinary window. NSWindow.Level exposes neither of those as a case.
    window.level = NSWindow.Level(rawValue: -1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    // The mover below owns the drag; leaving AppKit's own background drag on
    // would move the window a second time for the same gesture.
    window.isMovableByWindowBackground = false
    window.hidesOnDeactivate = false
    window.isExcludedFromWindowsMenu = true
    // Per-instance autosave key: parallel --instance launches must never
    // read/write the same saved placement — the shared key race crashed the second
    // launch ~15s after start. The restore happens inside setFrameAutosaveName, so the
    // default placement is applied only when nothing came back.
    let before = window.frame
    window.setFrameAutosaveName(strataWindowAutosaveName)
    if window.frame == before {
        placeCardWindowDefault(window)
    }
    window.dragMover = WindowDragMover(window)
    window.orderFrontRegardless() // level -1 does the stacking; no activate on launch
    // Nothing to settle here: AppKit restores the saved frame whenever the window comes
    // in — late enough to undo a fix made right after ordering — and
    // StrataWidgetWindow.setFrame substitutes our own size for whatever it restores
    // while keeping the corner the card sits in.
    cardWindow = window
}

/// The default placement in AppKit coordinates: origin is bottom-left, so the 30pt
/// inset is measured down from the top of the screen's visible frame, and the card is
/// kept clear of the Dock/menu bar even on a short screen.
func placeCardWindowDefault(_ window: NSWindow) {
    let visible = NSScreen.main?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = visible.minX + cardDefaultInset.x
    let y = max(visible.minY, visible.maxY - cardDefaultInset.y - window.frame.height)
    window.setFrameOrigin(NSPoint(x: x, y: y))
}

struct StrataCard: View {
    var body: some View {
        ZStack(alignment: Alignment(horizontal: .center, vertical: .top)) {
            // The frosted card: the desktop behind the widget, blurred, under the
            // design system's gradient (see cardSurface in components.swift).
            cardSurface(radius: 16)
            VStack(spacing: 0) {
                if strata.mini {
                    // Collapsed card: header + model + Speed only. If the server is
                    // down there is nothing to collapse to, so show the down state.
                    if let m = strata.payload {
                        miniBody(m)
                            .transition(.opacity)
                    } else {
                        downBody()
                            .transition(.opacity)
                    }
                } else {
                    tabPillsRow()
                    // One key covers both reasons the content changes — a tab click and
                    // the payload arriving or disappearing — so the swap always animates.
                    Group {
                        if let m = strata.payload {
                            if strata.tab == "server" {
                                serverBody(m)
                                    .transition(.opacity)
                            } else {
                                metricsBody(m)
                                    .transition(.opacity)
                            }
                        } else {
                            downBody()
                                .transition(.opacity)
                        }
                    }
                    .animation(motion, value: strataBodyKey)
                }
            }
            // In mini there are no pills, so give the header room to clear the close
            // button in the corner. 6 + the pill row's own 10 = the 16pt inset.
            .padding(.top, strata.mini ? 26 : 6)
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
            .animation(motion, value: strata.mini)
            // Close (X) in the top-right corner, clear of the pills and status pill.
            HStack {
                Spacer()
                closeCardButton()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 8)
            .padding(.trailing, 10)
            if !strata.mini {
                // The resize affordance, in the corner WindowDragMover treats as a
                // resize drag. Drawn by the card because a borderless window has no
                // AppKit grip, and pointless in the fixed-size mini card.
                ResizeGripView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
        .contentShape(Rectangle())
        // Double-click anywhere on the card collapses/expands it. The pills, the X, and
        // the grip own their own taps (higher gesture priority), so this only fires on
        // the background; the drag mover ignores a click with no movement.
        .onTapGesture(count: 2) { toggleMiniMode() }
        // LSUIElement means no Dock icon, so right-click is the quit affordance.
        .contextMenu {
            Button("Quit StrataWidget") { NSApp.terminate(nil) }
        }
    }
}

// Two dashes parallel to the corner, the way macOS marks a resize corner. Kept quiet:
// it is a hit target more than a decoration, so it is dim until hovered.
struct ResizeGripView: View {
    @State private var hovering = false

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 12)); p.addLine(to: CGPoint(x: 12, y: 0))
            }
            .stroke(hovering ? cMuted : cBorder, lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: 6, y: 12)); p.addLine(to: CGPoint(x: 12, y: 6))
            }
            .stroke(hovering ? cMuted : cBorder.opacity(0.7), lineWidth: 1)
        }
        .frame(width: 12, height: 12)
        .onHover { hovering = $0 }
    }
}

// MARK: - Entry point

// The card is an AppKit window, not a SwiftUI scene (see makeCardWindow): a scene
// window always has a frame view, and stripping its titlebar after the fact is what
// crashed the widget. The delegate therefore owns the window; the App struct exists
// for the lifecycle and for nothing else.
final class StrataAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        bootWidget() // chat.swift: loads persisted chats, starts the metrics poller and /health polling
        makeCardWindow()
    }

    // The card is never "closed" (it is a widget), and the chat/editor windows are
    // hidden rather than closed, so closing one must never end the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct StrataWidget: App {
    @NSApplicationDelegateAdaptor(StrataAppDelegate.self) private var delegate

    var body: some Scene {
        // Required for the App lifecycle, and deliberately inert: `Settings` opens no
        // window at launch, and an LSUIElement app has no menu item that could open it.
        Settings { EmptyView() }
    }
}
