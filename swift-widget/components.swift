import SwiftUI
import AppKit

// MARK: - Palette — Strata UI "Gainsty" design system, dark theme tokens.
// Mirrors the web app at :8080 (web/tokens.css, [data-theme="dark"]). The widget
// always renders the dark theme, so the dark token values are inlined here.

func hex(_ s: String, _ opacity: Double = 1) -> Color {
    let v = UInt32(String(s.dropFirst(1)), radix: 16) ?? 0
    return Color(.sRGB,
                 red: Double((v >> 16) & 0xFF) / 255,
                 green: Double((v >> 8) & 0xFF) / 255,
                 blue: Double(v & 0xFF) / 255,
                 opacity: opacity)
}

let cBlue = hex("#34d399") // st-accent: data, active tab, progress (green on the web app)
let cRed = hex("#ff5a6e") // st-danger: stop / server down / >90%
let cAmber = hex("#f5b53d") // st-warn: starting / queued / >75%
let cGreen = hex("#34d399") // st-accent: running / idle / <75%
let cOrange = hex("#fb923c") // temp (no web token — kept)
let cPurple = hex("#c084fc") // power (no web token — kept)
let cText = hex("#eef1f3") // st-ink: container text color
let cStrong = hex("#eef1f3") // values (st-ink, set in SF Mono)
let cMuted = hex("#8e979f") // st-ink-muted: labels/keys
let cDim = hex("#8e979f") // inactive pill text / footer (st-ink-muted)
let cBright = hex("#eef1f3") // active pill text (st-ink)
let cWhite = hex("#ffffff")
let cSurface = hex("#1d2226") // st-surface-2: raised surface (inactive pills, tab strip)
let cBorder = hex("#2a3036") // st-line: hairlines, dividers, pill outlines
let cSoft = hex("#c7cdd3") // st-ink-soft: body text in web chat bubbles
let cAccentInk = hex("#052e20") // st-accent-ink: text on a solid accent fill

// MARK: - Surfaces — the frosted card background (st-surface -> st-bg over the OS blur).

// The card's background is blurry because it sits on the OS' own frosted surface:
// `glassEffect` (macOS 26+ Liquid Glass) is what blurs whatever is behind the widget.
// Two things that look like they should work, don't: a transparent window never shows
// the desktop (a borderless window composites its own buffer), and a SwiftUI material
// layer only paints a grainy tint of the desktop and leaves it sharp. The design
// gradient then tints that frosted surface, at `cardFrosting`, so the blur reads through
// while st-ink stays legible. `frost: false` keeps the flat surface for the chat and
// server windows, which are ordinary windows that keep their own opaque background.
func cardSurface(radius: Double, frost: Bool = true) -> some View {
    // The frost sits *inside* the card's own rim: a 4pt margin keeps the OS blur off
    // the window's rounded edge, and the whole surface is clipped to the card's shape,
    // so the glass can neither spill past the corners nor leave a dark inset ellipse.
    let margin: Double = frost ? 4 : 0
    let card = RoundedRectangle(cornerRadius: radius)
    let gradient = LinearGradient(colors: [
        hex("#161a1d").opacity(frost ? cardFrosting : 0.94), // st-surface
        hex("#0e1113").opacity(min(1, (frost ? cardFrosting : 0.94) + 0.02)), // st-bg (OLED-dark)
    ], startPoint: UnitPoint(x: 0.37, y: 0.06), endPoint: UnitPoint(x: 0.63, y: 0.94))
    return ZStack {
        if frost, #available(macOS 26.0, *) {
            // The glass mask must be an explicit rounded rectangle. Without `in:`,
            // glassEffect defaults its mask to Capsule(), which morphs the frost into a
            // cylinder/stadium (a dark inset ellipse that spills past the rim). Passing
            // the card's own shape, inset by `margin`, makes the frost a rounded square
            // matching the card's width and height with a 4pt margin inside the rim.
            Color.clear
                .glassEffect(.regular.tint(hex("#0e1113").opacity(0.7)),
                             in: RoundedRectangle(cornerRadius: radius - margin))
                .padding(margin)
        }
        card.fill(gradient)
        card.stroke(cBorder.opacity(0.55), lineWidth: 1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(card)
}

// How opaque the gradient sits over the frosted glass: low enough that the desktop blur
// behind the card reads, high enough that the muted labels keep their contrast.
let cardFrosting: Double = {
    if #available(macOS 26.0, *) { return 0.72 }
    return 0.94 // older macOS has no OS blur for a borderless window: keep the flat surface
}()

// MARK: - Typography — Outfit (SIL OFL 1.1), the web app's face at :8080.
// The web app uses Outfit for UI text and a monospace face for numeric readouts
// (web/tokens.css: --st-font, --st-font-mono). Call sites use SwiftUI's own font
// machinery — .font(.custom("Outfit", size:)).weight(...) — which correctly selects a
// variable-face weight from the installed fonts/Outfit.ttf (SIL OFL) and falls back to
// the system UI face if Outfit isn't installed. Monospaced call sites keep SF Mono.

// JSX spinner string "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" — an array so spinFrame % 10 indexes it.
let spinnerGlyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

// MARK: - Motion (design system: "Always use transitions (150-300ms)" and
// "prefers-reduced-motion respected")

// AppKit's equivalent of CSS `prefers-reduced-motion` — the system "Reduce motion"
// toggle. Read live rather than cached at launch so a mid-session toggle applies
// to the next state change.
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// The single transition every state change uses. nil under reduced motion, which
// makes `.animation(motion, value:)` and `withAnimation(motion)` no-ops — so the
// widget snaps instead of animating rather than ignoring the setting.
var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

// JSX `col(p) = p>90 ? red : p>75 ? amber : green`.
func utilColor(_ pct: Double) -> Color {
    if pct > 90 { return cRed }
    if pct > 75 { return cAmber }
    return cGreen
}

// MARK: - Head (accent tick + 10px semibold uppercase, tracking 1.2, muted token;
// sectionHead in main.swift extends a hairline rule to the right edge)

func headView(_ title: String) -> some View {
    HStack(spacing: 6) {
        Rectangle()
            .fill(cBlue.opacity(0.9))
            .frame(width: 3, height: 10)
        Text(title)
            .font(.custom("Outfit", size: 10)).fontWeight(.semibold)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(cMuted)
    }
}

// MARK: - Sparkline (JSX `Spark`, w=92 h=18 — formula ported verbatim)
// pts: x = i/(len-1)*92, y = 18-1.5-((clamp(v,mn,mx)-mn)/span)*15.
// Area polygon 0,h pts w,h with a vertical gradient 0.30 → 0.02; stroke 1.5 round.
// <2 points → empty frame: we build empty Paths instead, which fill/stroke
// nothing, and the outer frame still yields the 92×18 slot.
//
// Darwin-27 note: Path shapes are sized by their bounding box, so the area
// (bbox 92×(18-minY)) and the line (bbox 92×(maxY-minY)) must be aligned by a
// shared corner. Both bboxes share top-left (0, minY), so ZStack aligns
// leading+top, and the outer frame bottom-aligns the ZStack (whose bottom is
// absolute y=18) onto the 18pt slot — an exact identity transform.

func sparkView(_ data: [Double?], _ lo: Double?, _ hi: Double?, _ color: Color) -> some View {
    let vals = data.compactMap { $0 } // JSX `.filter(v => v !== null)`
    let degenerate = vals.count < 2
    let mn = lo ?? (vals.min() ?? 0)
    let mx = hi ?? (vals.max() ?? 1)
    let span = (mx - mn) != 0 ? (mx - mn) : 1 // JSX `|| 1`
    let pts: [CGPoint] = degenerate ? [] : vals.enumerated().map { (i, v) in
        CGPoint(x: Double(i) / Double(vals.count - 1) * 92,
                y: 18 - 1.5 - ((clamped(v, mn, mx) - mn) / span) * 15)
    }
    let area = Path { p in
        guard !pts.isEmpty else { return }
        p.move(to: CGPoint(x: 0, y: 18))
        for pt in pts { p.addLine(to: pt) }
        p.addLine(to: CGPoint(x: 92, y: 18))
        p.closeSubpath()
    }
    let line = Path { p in
        guard !pts.isEmpty else { return }
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
    }
    return ZStack(alignment: Alignment(horizontal: .leading, vertical: .top)) {
        area
            .fill(.linearGradient(stops: [
                Gradient.Stop(color: color.opacity(0.30), location: 0),
                Gradient.Stop(color: color.opacity(0.02), location: 1),
            ], startPoint: .top, endPoint: .bottom))
        line
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
    .frame(width: 92, height: 18, alignment: Alignment(horizontal: .center, vertical: .bottom))
}

// MARK: - Row (JSX grid "52px 92px 1fr", gap 9; values now SF Mono — the
// technical/data mood of the design system's mono pairing, tabular numerals)

func rowView(label: String, value: String, data: [Double?], lo: Double?, hi: Double?, color: Color = cBlue) -> some View {
    HStack(spacing: 9) {
        Text(label)
            .font(.custom("Outfit", size: 11))
            .foregroundStyle(cMuted)
            .frame(width: 52, alignment: .leading)
        sparkView(data, lo, hi, color)
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(cStrong)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - KV (JSX space-between flex pair; keys system, values mono)

func kvView(key: String, value: String) -> some View {
    HStack {
        Text(key)
            .font(.custom("Outfit", size: 11))
            .foregroundStyle(cMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
        Text(value)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(cStrong)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Bar (JSX 5px capsule track + gradient fill; glow trimmed to the
// design system's "minimal glow / low white emission" note)

func barView(pct: Double, color: Color, width: Double = 92) -> some View {
    let w = max(5, clamped(pct, 0, 100) / 100 * width)
    return ZStack(alignment: Alignment(horizontal: .leading, vertical: .center)) {
        Capsule()
            .fill(cWhite.opacity(0.07))
            .frame(width: width, height: 5)
        Capsule()
            .fill(.linearGradient(stops: [
                Gradient.Stop(color: color.opacity(0.47), location: 0), // JSX `${color}77`
                Gradient.Stop(color: color, location: 1),
            ], startPoint: .leading, endPoint: .trailing)) // JSX `90deg` left→right
            .frame(width: w, height: 5)
            .shadow(color: color.opacity(0.25), radius: 3) // JSX was radius 4 / 0.33
            // Each poll re-reads the percentage; the fill glides to the new width
            // instead of snapping (design system: no instant state changes).
            .animation(motion, value: w)
    }
}

// MARK: - Tab pills (active: accent-tinted; inactive: raised surface token so the
// pill reads as elevation rather than a ghost. Hug-the-text .background() form —
// a bare Capsule in a ZStack is a greedy Shape and stretches in sparse tabs.)

// `size` defaults to the card's 10pt. The chat window passes 11pt: its pills are
// the primary controls there and 10pt Outfit is hard to read at desk distance.
func pillView(text: String, active: Bool, size: Double = 10) -> some View {
    Text(text)
        .font(.custom("Outfit", size: size)).fontWeight(.bold)
        .tracking(0.6)
        // Pills hug their label: a squeezed HStack must truncate rather than
        // wrap "High" onto two lines (the chat header is tight).
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(active ? cBright : cDim)
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
        .background(Capsule()
            .fill(active ? cBlue.opacity(0.16) : cSurface.opacity(0.85))
            .stroke(active ? cBlue.opacity(0.45) : cBorder.opacity(0.55), lineWidth: 1))
        // The pill row lives in StrataCard above the animated body, so this animates
        // the active/inactive swap on its own while the content below cross-fades.
        .animation(motion, value: active)
        // Active pills brighten with the accent; inactive ones with ink, so hover
        // never reads as a focus ring.
        .hoverLift(active ? cBlue : cWhite)
}

// MARK: - Status pill (JSX fill ≈0.11, border ≈0.22 of the status color)

func statusPillView(text: String, color: Color) -> some View {
    Text(text)
        .font(.custom("Outfit", size: 10)).fontWeight(.semibold)
        .tracking(0.6)
        .foregroundStyle(color)
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .background(Capsule()
            .fill(color.opacity(0.12))
            .stroke(color.opacity(0.30), lineWidth: 1))
        // Not clickable, so no hover — but the status color interpolates when the
        // server state changes rather than cutting between greens/ambers/reds.
        .animation(motion, value: text)
}

// MARK: - Start/Stop buttons (JSX pill buttons)

// Pointer-hand cursor while the hover is inside a clickable. AppKit drives the
// cursor, so SwiftUI's .onHover toggles NSCursor push/pop around the hover.
struct PointerCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func pointerCursor() -> some View { modifier(PointerCursor()) }

    func hoverLift(_ color: Color = cWhite, fill: Double = 0.05, stroke: Double = 0.75) -> some View {
        modifier(HoverLift(color: color, fill: fill, stroke: stroke))
    }
}

// MARK: - Hover state (design system: "Hover states with smooth transitions",
// "Instant state changes" forbidden)

// PointerCursor alone changes the cursor but not the control, which is not a
// visible hover state. This draws a tinted fill plus a brighter capsule stroke in
// the control's existing bounds, so nothing shifts layout (the anti-pattern
// against scale transforms) and the in/out transition runs on `motion`.
struct HoverLift: ViewModifier {
    var color: Color = cWhite
    var fill: Double = 0.05
    var stroke: Double = 0.75
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                Capsule()
                    .fill(color.opacity(hovering ? fill : 0))
                    .stroke(color.opacity(hovering ? stroke : 0), lineWidth: 1)
            )
            .animation(motion, value: hovering)
    }
}

struct ControlButton: View {
    let label: String
    let color: Color
    var loading: Bool = false
    let action: () -> Void

    // Same hug-the-text .background() form as the pills: the padded Text view
    // defines both the capsule size and (via contentShape) the tap hit area.
    // While loading the button dims, ignores taps, and runs an animated spinner
    // so a double-press never fires the control GET twice.
    var body: some View {
        Group {
            if loading {
                if reduceMotion {
                    // Reduced motion: keep the pending affordance, drop the 10 Hz
                    // glyph rotation.
                    Text("\(spinnerGlyphs[0]) launching…")
                } else {
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        let f = Int(ctx.date.timeIntervalSinceReferenceDate * 10) % spinnerGlyphs.count
                        Text("\(spinnerGlyphs[f]) launching…")
                    }
                }
            } else {
                Text(label)
            }
        }
        .font(.custom("Outfit", size: 11)).fontWeight(.semibold)
        .tracking(0.5)
        .foregroundStyle(color)
        .opacity(loading ? 0.7 : 1)
        .padding(.vertical, 6)
        .padding(.horizontal, 18)
        .frame(minWidth: 90)
        .background(Capsule()
            .fill(color.opacity(0.10))
            .stroke(color.opacity(0.45), lineWidth: 1))
        .hoverLift(color, fill: 0.08, stroke: 0.8)
        .animation(motion, value: loading)
        .contentShape(Rectangle())
        .allowsHitTesting(!loading)
        .onTapGesture { if !loading { action() } }
        .pointerCursor()
    }
}

// MARK: - Chat (bubbles, thinking blocks, effort selector — reuse the card's
// pillView/tokens; same hug-the-text pill treatment as everything else)

// Per-corner rounding, the web app's `border-radius` shorthand: chat bubbles are
// `--st-r-lg` with the corner nearest the input field flattened to 6px
// (web/components.css: .st-msg--user/.st-msg--assistant .st-bubble). Capsule is
// wrong here — on a multi-line block its radius is height/2, so the huge end
// curves carve into the first and last text lines.
struct RoundCorners: Shape {
    enum Corner: Hashable { case tl, tr, br, bl }

    var radius: CGFloat
    var corners: Set<Corner> = [.tl, .tr, .br, .bl]

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        func rr(_ c: Corner) -> CGFloat { corners.contains(c) ? r : 0 }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rr(.tl), y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - rr(.tr), y: rect.minY))
        if corners.contains(.tr) {
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rr(.br)))
        if corners.contains(.br) {
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.minX + rr(.bl), y: rect.maxY))
        if corners.contains(.bl) {
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rr(.tl)))
        if corners.contains(.tl) {
            p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        p.closeSubpath()
        return p
    }
}

// Chat bubble, mirroring .st-bubble: user turns sit right on the solid accent
// with accent-ink text, assistant answers left on the raised surface token with
// a hairline. While streaming, a caret marks growth mid-line (typing indicator
// without animation noise). Text stays selectable.
//
// No `.animation(_:value:)` on the text here: during a stream the fill shape
// animates toward its previous (shorter) bounds while the Text is already taller,
// so the bubble background lags behind the words and trails off mid-answer.
func bubbleView(role: String, text: String, streaming: Bool = false) -> some View {
    let user = role == "user"
    let shape = RoundCorners(radius: 14,
                             corners: user ? [.tl, .tr, .bl] : [.tl, .tr, .br])
    let align: Alignment = user ? .trailing : .leading
    return Text(chatRichText(text + (streaming ? "▌" : "")))
        .font(.custom("Outfit", size: 13))
        .lineSpacing(4) // ≈ the web's line-height 1.55 at this size
        .foregroundStyle(user ? cAccentInk : cSoft)
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(shape.fill(user ? cBlue : Color(cSurface).opacity(0.9)))
        .overlay(shape.stroke(user ? Color.clear : cBorder.opacity(0.7), lineWidth: 1))
        // Bounded like .st-msg { max-width: 720px }: the bubble never spans the
        // whole window, it sits against its own side. The cap is generous enough
        // that a widened window reads as a wider column rather than a line
        // length pinned at the old 380pt layout.
        .frame(maxWidth: 460, alignment: align)
        .frame(maxWidth: .infinity, alignment: align)
}

// Inline Markdown only (`**bold**`, `*it*`, `` `code` ``, links). Block syntax
// is left as literal text on purpose: `.inlineOnlyPreservingWhitespace` keeps
// the newlines a streaming answer relies on, and half-parsed markup during a
// stream falls back to the literal string rather than eating characters.
func chatRichText(_ s: String) -> AttributedString {
    if let a = try? AttributedString(markdown: s,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return a
    }
    return AttributedString(s)
}

// Thinking block: collapsed by default (▸ header), tap expands to the mono
// reasoning body. While thinking streams the header ends with an ellipsis.
func thinkBlock(reasoning: String, open: Bool, streaming: Bool = false) -> some View {
    return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 5) {
            Text(open ? "▾" : "▸")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(cBlue.opacity(0.8))
            Text("thinking · \(fmtGrouped(Double(reasoning.count))) chars\(streaming ? "…" : "")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(cDim)
        }
        if open {
            Text(reasoning)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(cDim.opacity(0.85))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 8)
    // Rounded rect, not Capsule: expanded, this block is tall, and a capsule's
    // radius (height/2) would carve a huge oval out of the reasoning body.
    .background(RoundCorners(radius: 10).fill(Color(cSurface).opacity(open ? 0.55 : 0.0)))
    .overlay(RoundCorners(radius: 10).stroke(cBorder.opacity(0.5), lineWidth: 1))
    // Collapsed the header hugs its label (the greedy Capsule would otherwise
    // stretch across the transcript and read as a centred bar); expanded it
    // takes the width it is given so the reasoning body wraps.
    .fixedSize(horizontal: !open, vertical: true)
}

// Effort selector: Off/Low/Med/High write reasoning_effort none|low|medium|high
// into ChatModel (the pill row is the writer; active pill filled teal). The
// `select` callback is staged into a global slot because onTapGesture handlers
// are escaping closures and cannot capture a non-escaping function parameter.
var chatEffortFn: (String) -> Void = { _ in }
func effortPillsRow(current: String, select: @escaping (String) -> Void) -> some View {
    chatEffortFn = select
    return HStack(spacing: 6) {
        pillView(text: "Off", active: current == "none", size: 11).onTapGesture { chatEffortFn("none") }.pointerCursor()
        pillView(text: "Low", active: current == "low", size: 11).onTapGesture { chatEffortFn("low") }.pointerCursor()
        pillView(text: "Med", active: current == "medium", size: 11).onTapGesture { chatEffortFn("medium") }.pointerCursor()
        pillView(text: "High", active: current == "high", size: 11).onTapGesture { chatEffortFn("high") }.pointerCursor()
    }
}

// MARK: - Footer divider (border token, visible on both card gradient stops)

func dividerView() -> some View {
    Rectangle()
        .fill(cBorder.opacity(0.55))
        .frame(height: 1)
}
