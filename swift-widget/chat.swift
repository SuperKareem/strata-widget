import SwiftUI
import Foundation

// MARK: - Chat — the widget's second window (plan: docs/CHAT_PLAN.md 2026-11-04)
//
// The card window cannot become key (hidden title bar, level -1 — documented at
// strata-app.swift:363-365), and typing is the whole point of a chat, so the
// chat lives in its own NSWindow, opened from the Chat pill in the card body.
// Lifecycle mirrors serverDialogWindow exactly: create once, reuse, hide with
// orderOut(nil). A window that has an NSHostingController attached is NEVER
// close()/release()'d — the objc_release SIGSEGV is documented at
// strata-app.swift:417-432.
//
// Transport note vs the plan: this Foundation build has no Pipe.readabilityHandler
// and no Popen (verified by compile), so streaming is the fetchBody pattern —
// Process + /usr/bin/curl -sN writing to a temp file — with the SSE file tailed
// every 200ms in a Task loop. curl's --max-time 600 means the wrapper /bin/sh
// ALWAYS appends the `data: __END__` sentinel line once curl leaves, so the
// loop terminates deterministically (stream done, killed, or timed out). Stop
// pkill -f's the curl -A marker (kills wrapper + curl), which lands the
// sentinel and ends the stream with what streamed so far.

// MARK: Wire shapes — persisted chats and the SSE protocol.
// Never persisted while streaming: chatPersist() filters $0.streaming.
struct MsgWire: Codable {
    let role: String
    let content: String
    // Thinking-only assistant turns are sent back with reasoning_content, like
    // the web app (serve/web/app.js): roles then stay alternating.
    let reasoning_content: String?
}
struct ChatWire: Codable {
    let id: UUID
    let title: String
    let createdAt: Int
    let messages: [MsgWire]
}

// Runtime chat shapes (streaming flag is runtime-only).
struct ChatMsg {
    var role: String
    var content: String
    var reasoning: String
    var streaming: Bool
}
struct ChatRec {
    var id: UUID
    var title: String
    var createdAt: Int
    var messages: [ChatMsg]
}

// SSE chunk decode, loose: every field optional, extra keys (index,
// finish_reason, created, model…) are simply not decoded.
struct DeltaWire: Decodable {
    let content: String?
    let reasoning_content: String?
}
struct ChoiceWire: Decodable { let delta: DeltaWire? }
struct UsageWire: Decodable { let completion_tokens: Double? }
struct ErrorWire: Decodable { let message: String? }
struct SSEWire: Decodable {
    let choices: [ChoiceWire]?
    let usage: UsageWire?
    let error: ErrorWire?
}
// /health on the metrics port for the chat footer (model · ctx), like the web
// app's drawer header.
struct HealthWire: Decodable {
    let model: String?
    let max_context: Double?
}

// MARK: - Chat state — singleton; the effort selector writes effort, transport
// process handles are plain (non-observable) globals.
@Observable final class ChatModel {
    var chats: [ChatRec] = []
    var activeID = UUID()
    var effort: String = "high"
    var draft = ""
    var streaming = false
    var pickerOpen = false
    var lastTokS: Double? = nil
    var lastError: String? = nil
    var healthModel: String? = nil
    var healthCtx: Double? = nil
    var expandedThinking: Set<String> = []
}
let chatModel = ChatModel()

var chatWindow: NSWindow? = nil
var chatWindowVisible = false
private var chatStreamProc: Process? = nil
private var chatKillMarker = ""
private var chatStreamID = UUID() // the chat a running stream belongs to
var chatDoneSeen = false
var chatStreamStartMs = 0

func chatFindByID(_ id: UUID) -> Int {
    chatModel.chats.firstIndex { $0.id == id } ?? -1
}
var chatIndex: Int { chatFindByID(chatModel.activeID) }
var chatTranscript: [ChatMsg] {
    let i = chatIndex
    guard i >= 0 else { return [] }
    return chatModel.chats[i].messages
}
var chatTitle: String {
    let i = chatIndex
    guard i >= 0 else { return "Strata Chat" }
    return chatModel.chats[i].title
}

// Auto-scroll trigger for the transcript: it changes whenever the transcript
// gains a message or the streaming turn gains characters, so the newest line
// stays above the input field while the answer streams.
var chatScrollSignal: String {
    let msgs = chatTranscript
    guard let last = msgs.last else { return "0:0:0" }
    return "\(msgs.count):\(last.content.count):\(last.reasoning.count)"
}

// MARK: - Persistence (UserDefaults suite is per-instance like the rest of the
// widget: strata.chats JSON, strata.chatActive, strata.effort default high)
func chatPersist() {
    let wires: [ChatWire] = chatModel.chats.map { c in
        ChatWire(id: c.id, title: c.title, createdAt: c.createdAt,
                 messages: c.messages.filter { $0.streaming == false }.map { m in
                     MsgWire(role: m.role, content: m.content,
                             reasoning_content: m.reasoning.isEmpty ? nil : m.reasoning)
                 })
    }
    if let enc = try? JSONEncoder().encode(wires) { strataDefaults.set(enc, forKey: "strata.chats") }
    strataDefaults.set(chatModel.activeID.uuidString, forKey: "strata.chatActive")
    strataDefaults.set(chatModel.effort, forKey: "strata.effort")
}

func chatSanitizeEffort(_ v: String) -> String {
    switch v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "none", "low", "medium", "high": return v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    default: return "high"
    }
}

func chatLoad() {
    if let data = strataDefaults.data(forKey: "strata.chats"),
       let wires = try? JSONDecoder().decode([ChatWire].self, from: data) {
        chatModel.chats = wires.map { c in
            ChatRec(id: c.id, title: c.title, createdAt: c.createdAt,
                    messages: c.messages.map { ChatMsg(role: $0.role, content: $0.content,
                                                       reasoning: $0.reasoning_content ?? "", streaming: false) })
        }
    }
    if chatModel.chats.count > 30 { chatModel.chats = Array(chatModel.chats.suffix(30)) }
    for i in chatModel.chats.indices where chatModel.chats[i].messages.count > 200 {
        chatModel.chats[i].messages = Array(chatModel.chats[i].messages.suffix(200))
    }
    if chatModel.chats.isEmpty {
        chatModel.chats = [ChatRec(id: UUID(), title: "New chat", createdAt: nowMs(), messages: [])]
    }
    if let s = strataDefaults.string(forKey: "strata.chatActive"), let u = UUID(uuidString: s),
       chatModel.chats.contains(where: { $0.id == u }) { chatModel.activeID = u }
    chatModel.effort = chatSanitizeEffort(strataDefaults.string(forKey: "strata.effort") ?? "high")
}

// MARK: - Store operations
func chatSetActive(_ id: UUID) {
    guard chatModel.chats.contains(where: { $0.id == id }) else { return }
    chatModel.activeID = id
    chatPersist()
}
func chatPickChat(_ id: UUID) {
    chatSetActive(id)
    chatModel.pickerOpen = false
}
func chatTogglePicker() {
    chatModel.pickerOpen = !chatModel.pickerOpen
}
func chatClear() {
    guard chatModel.streaming == false else { return }
    let i = chatIndex
    guard i >= 0 else { return }
    chatModel.chats[i].messages = []
    chatPersist()
}
func chatNewChat() {
    guard chatModel.streaming == false else { return }
    let fresh = ChatRec(id: UUID(), title: "New chat", createdAt: nowMs(), messages: [])
    chatModel.chats.append(fresh)
    if chatModel.chats.count > 30 { chatModel.chats = Array(chatModel.chats.suffix(30)) }
    chatModel.activeID = fresh.id
    chatPersist()
}
// Deleting a chat. The chat that owns a running stream is stopped first, so curl
// never keeps writing into a transcript that no longer exists. Deleting the
// active chat selects the newest remaining one; the list is never left empty,
// because the window always needs a chat to type into.
func chatDeleteChat(_ id: UUID) {
    if chatModel.streaming && chatStreamID == id {
        chatKill()
        chatFinalizeStream()
    }
    let i = chatFindByID(id)
    guard i >= 0 else { return }
    chatModel.chats.remove(at: i)
    if chatModel.activeID == id {
        if let next = chatModel.chats.last {
            chatModel.activeID = next.id
        } else {
            let fresh = ChatRec(id: UUID(), title: "New chat", createdAt: nowMs(), messages: [])
            chatModel.chats = [fresh]
            chatModel.activeID = fresh.id
        }
    }
    chatPersist()
}

func chatToggleThinking(_ key: String) {
    if chatModel.expandedThinking.contains(key) { chatModel.expandedThinking.remove(key) }
    else { chatModel.expandedThinking.insert(key) }
}
func chatThinkingOpen(_ i: Int) -> Bool {
    chatModel.expandedThinking.contains("\(chatModel.activeID.uuidString):\(i)")
}
func chatThinkKey(_ i: Int) -> String { "\(chatModel.activeID.uuidString):\(i)" }
func chatSetEffort(_ v: String) {
    chatModel.effort = chatSanitizeEffort(v)
    chatPersist()
}

func chatFail(_ msg: String) {
    chatModel.lastError = msg
    if chatModel.streaming { chatFinalizeStream() }
}

func chatFinalizeStream() {
    let i = chatFindByID(chatStreamID)
    if i >= 0, let j = chatModel.chats[i].messages.lastIndex(where: { $0.streaming }) {
        if chatModel.chats[i].messages[j].content.isEmpty && chatModel.chats[i].messages[j].reasoning.isEmpty {
            chatModel.chats[i].messages.remove(at: j) // never keep an empty placeholder
        } else {
            chatModel.chats[i].messages[j].streaming = false
        }
    }
    chatModel.streaming = false
    chatModel.chats = Array(chatModel.chats.suffix(30))
    chatPersist()
}

// MARK: - SSE line protocol (plan §chat.swift transport list)
func chatApplyLine(_ line: String) {
    if line.isEmpty || line.hasPrefix(":") { return } // blank + ": keep-alive" comments
    var payload = line
    if payload.hasPrefix("data:") {
        payload = String(payload.dropFirst(5))
        if payload.hasPrefix(" ") { payload = String(payload.dropFirst(1)) }
    } else {
        // not an SSE line: server answered non-200 and the body's first line is
        // plain JSON/text — surface it as the error bubble.
        let t = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        chatModel.lastError = String(t.prefix(140))
        return
    }
    let t = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if t == "[DONE]" || t == "__END__" { chatDoneSeen = true; return }
    guard let json = try? JSONDecoder().decode(SSEWire.self, from: Data(payload.utf8)) else {
        chatModel.lastError = String(payload.prefix(140))
        return
    }
    if json.choices == nil && json.usage == nil, json.error != nil {
        chatModel.lastError = String((json.error?.message ?? payload).prefix(140))
        chatDoneSeen = true // an error body ends the stream; curl exits → sentinel
        return
    }
    let i = chatFindByID(chatStreamID)
    guard i >= 0 else { return }
    if let choices = json.choices, let first = choices.first, let delta = first.delta {
        guard let j = chatModel.chats[i].messages.lastIndex(where: { $0.streaming }) else { return }
        if let c = delta.content { chatModel.chats[i].messages[j].content += c }
        if let r = delta.reasoning_content { chatModel.chats[i].messages[j].reasoning += r }
    }
    // Final chunk usage → tokens/sec for the footer status line.
    if let usage = json.usage, let toks = usage.completion_tokens, toks > 0 {
        let secs = max(0.1, Double(nowMs() - chatStreamStartMs) / 1000)
        chatModel.lastTokS = toks / secs
    }
}

func chatSendDraft() {
    let text = chatModel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    chatModel.draft = ""
    guard !text.isEmpty, chatModel.streaming == false else { return } // send disabled while streaming
    let i = chatIndex
    guard i >= 0 else { return }
    chatModel.chats[i].messages = Array(chatModel.chats[i].messages.suffix(40)) // keep the last 40 on send
    chatModel.chats[i].messages.append(ChatMsg(role: "user", content: text, reasoning: "", streaming: false))
    if chatModel.chats[i].title == "New chat" { chatModel.chats[i].title = String(text.prefix(28)) }
    chatStreamID = chatModel.chats[i].id
    chatModel.chats[i].messages.append(ChatMsg(role: "assistant", content: "", reasoning: "", streaming: true))
    chatModel.streaming = true
    chatModel.lastError = nil
    chatPersist() // the streaming placeholder is filtered by chatPersist
    Task { await chatStreamReply() }
}

// MARK: - Transport: curl -sN through /bin/sh so the wrapper always leaves the
// `data: __END__` sentinel after curl. Body is a -d @file (no argv quoting
// issues for long transcripts); the -A marker names the process for pkill.
func chatShellQuote(_ raw: String) -> String {
    String(raw.filter { $0 != "'" }) // single quotes wrap these args; drop any in values
}

func chatJSONQuote(_ s: String) -> String {
    var out = "\""
    for ch in s {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out += String(ch)
        }
    }
    return out + "\""
}

func chatKill() {
    guard !chatKillMarker.isEmpty else { return }
    let marker = chatKillMarker
    chatKillMarker = ""
    Task {
        let pk = Process()
        pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pk.arguments = ["-f", marker]
        do { try pk.run() } catch {}
        pk.waitUntilExit()
    }
}

func chatStreamReply() async {
    guard let url = chatURL() else {
        chatFail("chat endpoint not configured")
        return
    }
    // model: /health first (chat footer keeps it live); /metrics engine.model
    // is the fallback while health lags.
    let model = chatModel.healthModel ?? runningModel() ?? "default"
    let history = chatTranscript.filter { $0.streaming == false }.map {
        MsgWire(role: $0.role, content: $0.content, reasoning_content: $0.reasoning.isEmpty ? nil : $0.reasoning)
    }
    var msgParts: [String] = []
    for m in history {
        var fields = ["\"role\":\(chatJSONQuote(m.role))", "\"content\":\(chatJSONQuote(m.content))"]
        if let r = m.reasoning_content { fields.append("\"reasoning_content\":\(chatJSONQuote(r))") }
        msgParts.append("{" + fields.joined(separator: ",") + "}")
    }
    // No sampling fields beyond reasoning_effort: the server then applies the
    // model card's own thinking set (verified contract note in the plan).
    var body = "{\"model\":\(chatJSONQuote(model))"
    body += ",\"messages\":[\(msgParts.joined(separator: ","))]"
    body += ",\"stream\":true"
    body += ",\"reasoning_effort\":\(chatJSONQuote(chatModel.effort))}"

    let pid = getpid()
    chatKillMarker = "strata-chat-\(strataInstance)-\(pid)"
    let bodyPath = "/tmp/strata-chat-\(strataInstance)-\(pid).json"
    let ssePath = "/tmp/strata-chat-\(strataInstance)-\(pid).sse"
    do { try body.write(to: URL(fileURLWithPath: bodyPath), atomically: true, encoding: .utf8) } catch {
        chatFail("chat send: cannot stage request body")
        return
    }
    defer { _ = remove(bodyPath); _ = remove(ssePath) }

    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    var script = "curl -sN --max-time 600 -A '\(chatKillMarker)' -X POST -H 'Content-Type: application/json'"
    if !strata.apiKey.isEmpty { script += " -H 'Authorization: Bearer \(chatShellQuote(strata.apiKey))'" }
    script += " -d '@\(bodyPath)' '\(chatShellQuote(url))' -o '\(ssePath)'; printf 'data: __END__\n' >> '\(ssePath)'"
    sh.arguments = ["-c", script]
    do { try sh.run() } catch {
        chatFail("chat send: could not spawn curl")
        chatFinalizeStream()
        return
    }
    chatStreamProc = sh
    chatDoneSeen = false
    chatStreamStartMs = nowMs()

    // Tail the SSE file. Only bytes up to the last newline are parsed, so a
    // half-written JSON line or a split multi-byte char never gets decoded —
    // the unconsumed tail is re-read next tick (and a decode failure on a
    // still-partial file just skips the tick).
    var consumed = 0 // characters already parsed
    while chatDoneSeen == false, nowMs() - chatStreamStartMs < 615_000 {
        try? await Task.sleep(for: .milliseconds(200))
        guard let txt = try? String(contentsOf: URL(fileURLWithPath: ssePath), encoding: .utf8) else { continue }
        // line-split over the fresh slice; a partial line's chars stay uncounted
        var line = ""
        var lineLen = 0
        var processed = 0
        for ch in String(txt.dropFirst(consumed)) {
            lineLen += 1
            if ch == "\n" {
                chatApplyLine(line)
                processed += lineLen
                line = ""
                lineLen = 0
                if chatDoneSeen { break }
            } else {
                line += String(ch)
            }
        }
        consumed += processed
    }
    // Final flush of whatever arrived between the last tick and process exit
    // (the sentinel itself is the terminator, written after curl finishes).
    if let txt = try? String(contentsOf: URL(fileURLWithPath: ssePath), encoding: .utf8) {
        var line = ""
        for ch in String(txt.dropFirst(consumed)) {
            if ch == "\n" { chatApplyLine(line); line = "" } else { line += String(ch) }
            if chatDoneSeen { break }
        }
    }
    // Processes already exited when the sentinel was seen — this reaps
    // instantly (otherwise the 600s cap has already fired).
    if let proc = chatStreamProc { proc.waitUntilExit() }
    chatStreamProc = nil
    chatKillMarker = ""
    chatFinalizeStream()
}

// MARK: - Chat window view (380pt, mirrors the card: same gradient, tokens,
// pill treatments; reduce-motion honored through `motion` everywhere)
struct ChatWindowView: View {
    @FocusState private var inputFocus: Bool

    var body: some View {
        VStack(spacing: 10) {
            // Row 1 is the identity row: the chat title takes the room it can
            // (truncating rather than pushing the controls off), and the two
            // controls hug their labels. Row 2 is the effort selector, which
            // needs the full width for Off/Low/Med/High.
            HStack(spacing: 8) {
                Text(chatTitle)
                    .font(.custom("Outfit", size: 13)).fontWeight(.bold)
                    .tracking(0.3)
                    .foregroundStyle(cStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                pillView(text: chatModel.pickerOpen ? "Chats ▴" : "Chats ▾",
                         active: chatModel.pickerOpen, size: 11)
                    .onTapGesture { chatTogglePicker() }
                    .pointerCursor()
                    // The dropdown hangs from this pill's bounds as an overlay on the
                    // whole view (see chatPickerOverlay), so opening it never pushes
                    // the effort row or the transcript down.
                    .anchorPreference(key: ChatPickerAnchorKey.self, value: .bounds) { $0 }
                pillView(text: "✕", active: false, size: 11)
                    .onTapGesture { closeChatWindow() }
                    .pointerCursor()
            }
            HStack(spacing: 6) {
                Text("effort")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(cDim)
                effortPillsRow(current: chatModel.effort, select: { chatSetEffort($0) })
                Spacer(minLength: 0)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    let msgs = chatTranscript
                    if msgs.isEmpty {
                        chatEmptyView()
                    }
                    ForEach(Array(msgs.enumerated()), id: \.offset) { (idx, m) in
                        VStack(alignment: .leading, spacing: 4) {
                            if !m.reasoning.isEmpty {
                                thinkBlock(reasoning: m.reasoning, open: chatThinkingOpen(idx),
                                           streaming: m.streaming && m.content.isEmpty)
                                    .onTapGesture { chatToggleThinking(chatThinkKey(idx)) }
                            }
                            if m.streaming || !m.content.isEmpty {
                                bubbleView(role: m.role, text: m.content, streaming: m.streaming)
                            }
                        }
                        .padding(.bottom, 8)
                        .id("chat-msg-\(idx)")
                    }
                    // Anchor below the last row so scrollTo(bottom) keeps the newest
                    // line of a streaming answer visible instead of scrolling under
                    // the input field.
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .onChange(of: chatScrollSignal) { _, _ in
                    // Follow the reply only while it streams; scrolling back through
                    // history must not get yanked down by a token arriving.
                    guard chatModel.streaming else { return }
                    withAnimation(motion) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 8) {
                TextField("ask the strata server…", text: Binding(
                    get: { chatModel.draft },
                    set: { chatModel.draft = $0 }
                ))
                    .font(.custom("Outfit", size: 13))
                    .foregroundStyle(cStrong)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color(cSurface).opacity(0.85))
                    .overlay(fieldStroke(focused: inputFocus))
                    .animation(motion, value: inputFocus)
                    .focused($inputFocus)
                    .onSubmit { chatSendDraft() }
                    // The window is key by the time this fires; the short delay
                    // lets the field become first responder so the caret blinks
                    // immediately on open (same pattern as ServerDialogView).
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            inputFocus = true
                        }
                    }
                HStack(spacing: 6) {
                    pillView(text: "Send ⏎", active: chatModel.streaming == false, size: 11)
                        .onTapGesture { chatSendDraft() }
                        .pointerCursor()
                    pillView(text: "Clear", active: false, size: 11)
                        .onTapGesture { chatClear() }
                        .pointerCursor()
                    pillView(text: "New chat", active: false, size: 11)
                        .onTapGesture { chatNewChat() }
                        .pointerCursor()
                    pillView(text: "Stop", active: chatModel.streaming, size: 11)
                        .onTapGesture { chatKill() }
                        .pointerCursor()
                }
            }
            Text(chatFooterLine)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(chatModel.lastError == nil ? cDim : cRed)
        }
        .padding(14)
        // The window is resizable (openChatWindow), so the content fills whatever
        // size it is given instead of pinning a 380×500 frame. contentMinSize on
        // the window keeps these rows from being squeezed below a usable width.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.linearGradient(colors: [
                    hex("#161a1d").opacity(0.94), // st-surface
                    hex("#0e1113").opacity(0.96), // st-bg (OLED-dark)
                ], startPoint: UnitPoint(x: 0.37, y: 0.06), endPoint: UnitPoint(x: 0.63, y: 0.94)))
                .stroke(cBorder.opacity(0.55), lineWidth: 1)
        )
        .overlayPreferenceValue(ChatPickerAnchorKey.self) { anchor in chatPickerOverlay(anchor) }
    }
}

// Preference that carries the Chats pill's bounds up to the view's overlay.
struct ChatPickerAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// The chats dropdown, floated over the transcript rather than inserted into the
// VStack: the header, effort row and transcript hold their exact positions whether
// it is open or not (no layout shift). `geo[anchor]` is the pill's rect in this
// overlay's coordinate space, so the panel hangs just below the pill and is
// clamped inside the window. Clicking outside the list dismisses it.
@ViewBuilder
func chatPickerOverlay(_ anchor: Anchor<CGRect>?) -> some View {
    if chatModel.pickerOpen, let anchor {
        GeometryReader { geo in
            let pill = geo[anchor]
            let width = min(340.0, max(230.0, geo.size.width - 28))
            let x = min(max(14.0, pill.maxX - width), max(14.0, geo.size.width - width - 14))
            let y = min(pill.maxY + 8, max(40.0, geo.size.height - 90))
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { chatModel.pickerOpen = false }
                chatPickerDropdown(width: width, listMaxHeight: max(90.0, geo.size.height - y - 34))
                    .padding(.leading, x)
                    .padding(.top, y)
            }
        }
    }
}

// Uniform rows (fixed height), so the list's own height is computed rather than
// measured: the panel hugs its content when there are two chats and scrolls once
// it would run past the bottom of the window.
func chatPickerDropdown(width: Double, listMaxHeight: Double) -> some View {
    let rows = Array(chatModel.chats.suffix(12)).reversed()
    let rowH: CGFloat = 36
    let listH = min(Double(rows.count) * Double(rowH) + 12, listMaxHeight)
    return VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            headView("chats")
            Spacer(minLength: 8)
            Text("\(chatModel.chats.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(cDim)
            pillView(text: "✕", active: false, size: 11)
                .onTapGesture { chatModel.pickerOpen = false }
                .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        dividerView()
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                ForEach(Array(rows), id: \.id) { c in
                    chatPickerRow(c).frame(height: rowH)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .frame(height: CGFloat(listH), alignment: .top)
    }
    .frame(width: width, alignment: .top)
    .background(
        RoundedRectangle(cornerRadius: 12)
            .fill(.linearGradient(colors: [
                hex("#1d2226").opacity(0.98), // st-surface-2
                hex("#14181b").opacity(0.98),
            ], startPoint: UnitPoint(x: 0.37, y: 0.06), endPoint: UnitPoint(x: 0.63, y: 0.94)))
            .stroke(cBorder.opacity(0.7), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.45), radius: 12, y: 4)
}

// One row: tap anywhere selects the chat, the ✕ at its right end deletes it. The
// delete control is a real Button, so its click is consumed before the row's
// tap gesture can fire — selecting and deleting never collide.
func chatPickerRow(_ c: ChatRec) -> some View {
    let active = c.id == chatModel.activeID
    return HStack(spacing: 8) {
        Text(c.title)
            .font(.custom("Outfit", size: 12)).fontWeight(.semibold)
            .tracking(0.4)
            .foregroundStyle(active ? cBright : cMuted)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer(minLength: 8)
        Text("\(c.messages.count) msgs")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(cDim)
        ChatDeleteButton(chatID: c.id)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 10)
    .background(RoundCorners(radius: 10)
        .fill(active ? cBlue.opacity(0.16) : Color(cSurface).opacity(0.55)))
    .overlay(RoundCorners(radius: 10)
        .stroke(active ? cBlue.opacity(0.45) : cBorder.opacity(0.55), lineWidth: 1))
    .contentShape(RoundCorners(radius: 10))
    .onTapGesture { chatPickChat(c.id) }
    .pointerCursor()
}

struct ChatDeleteButton: View {
    let chatID: UUID
    @State private var hovering = false

    var body: some View {
        Button {
            chatDeleteChat(chatID)
        } label: {
            Text("✕")
                .font(.system(size: 12, design: .monospaced)).fontWeight(.bold)
                .foregroundStyle(hovering ? cRed : cDim)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(RoundCorners(radius: 8)
                    .fill(hovering ? cRed.opacity(0.16) : Color.clear))
                .overlay(RoundCorners(radius: 8)
                    .stroke(hovering ? cRed.opacity(0.55) : Color.clear, lineWidth: 1))
                .contentShape(RoundCorners(radius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(motion, value: hovering)
        .pointerCursor()
        .accessibilityLabel("Delete this chat")
    }
}

func chatEmptyView() -> some View {
    VStack(spacing: 6) {
        Text("A new chat is open — type below and press ↩.")
            .font(.custom("Outfit", size: 12))
            .foregroundStyle(cMuted)
        Text("↩ send · ⇧↩ newline · Stop ends the stream · ✕ closes the window")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(cDim)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

var chatFooterLine: String {
    if let err = chatModel.lastError { return "last error: \(err)" }
    var s = "model: \(chatModel.healthModel ?? runningModel() ?? "–")"
    if let c = chatModel.healthCtx { s += " · ctx \(fmtTokK(c))" }
    if let t = chatModel.lastTokS { s += " · last \(fmtFixed(t, digits: 0)) tok/s" }
    return s
}
func fmtTokK(_ v: Double) -> String {
    guard v.isFinite, v >= 1000 else { return String(Int(v.rounded())) }
    return String(Int((v / 1000).rounded())) + "k"
}

// MARK: - Window lifecycle — reuse; hide with orderOut; never close/release.
// NSApp.activate is required on every open: the app is LSUIElement, so a window
// can otherwise appear with no keyboard focus (cursor would never blink).
func openChatWindow() {
    chatWindowVisible = true
    if let existing = chatWindow {
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let window = NSWindow()
    let hosting = NSHostingController(rootView: ChatWindowView())
    // Resizing needs the hosting view to follow the window's frame instead of the
    // other way round: NSHostingController defaults to .preferredContentSize, which
    // pins the window to the SwiftUI view's ideal size and ignores resize drags.
    hosting.sizingOptions = []
    window.contentViewController = hosting
    window.styleMask = [.titled, .closable, .resizable]
    window.title = "Strata Chat"
    // Room for the 13pt transcript plus the input row at the narrowest useful
    // width, with a sane ceiling so a maximised drag stays a chat window.
    window.contentMinSize = NSSize(width: 340, height: 400)
    window.contentMaxSize = NSSize(width: 1100, height: 1600)
    // Per-instance autosave key (same rule as strataWindowAutosaveName): parallel --instance
    // launches must never share saved placement. The restore happens inside
    // setFrameAutosaveName, so the default size is applied only when nothing came
    // back — otherwise the hosting controller's own fitting size survives and the
    // first open lands at whatever size the SwiftUI view happened to propose.
    let before = window.frame
    window.setFrameAutosaveName("StrataChat.\(strataInstance)")
    let restored = window.frame != before
    window.isMovableByWindowBackground = true
    window.level = .normal // key-capable: the card window never becomes key; this one must
    window.makeKeyAndOrderFront(nil)
    // After the first display pass (and only when autosave restored nothing): the
    // default size. Setting it earlier loses — the hosting view's own fitting size
    // is applied to the window during that pass and overrides it.
    if !restored {
        window.setContentSize(NSSize(width: 420, height: 560))
        window.center()
    }
    chatWindow = window
    NSApp.activate(ignoringOtherApps: true)
}

func closeChatWindow() {
    chatWindowVisible = false
    chatModel.pickerOpen = false // a hidden window must not reopen with the list open
    chatKill() // close kills any running curl before hiding
    chatWindow?.orderOut(nil)
    // Hand key status back to the card (the Server dialog window, if open,
    // stays as it is).
    cardWindow?.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
}

func toggleChatWindow() {
    if chatWindowVisible { closeChatWindow() } else { openChatWindow() }
}

// MARK: - Boot: load persisted chats, start the metrics poller, and poll /health
// on the metrics port every 10s for the chat footer.
func startChatHealth() {
    Task {
        while !Task.isCancelled {
            if let url = healthURL(), let body = await fetchBody(url),
               let h = try? JSONDecoder().decode(HealthWire.self, from: Data(body.utf8)) {
                chatModel.healthModel = h.model ?? chatModel.healthModel
                chatModel.healthCtx = h.max_context ?? chatModel.healthCtx
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

func bootWidget() {
    chatLoad()
    startPolling()
    startChatHealth()
}
