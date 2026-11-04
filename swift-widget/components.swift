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

// MARK: - Typography — Outfit (SIL OFL 1.1), the web app's face at :8080.
// The web app uses Outfit for UI text and a monospace face for numeric readouts
// (web/tokens.css: --st-font, --st-font-mono). Call sites use SwiftUI's own font
// machinery — .font(.custom("Outfit", size:)).weight(...) — which correctly selects a
// variable-face weight from the installed fonts/Outfit.ttf (SIL OFL) and falls back to
// the system UI face if Outfit isn't installed. Monospaced call sites keep SF Mono.

// JSX spinner string "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" — an array so spinFrame % 10 indexes it.
let spinnerGlyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

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
    }
}

// MARK: - Tab pills (active: accent-tinted; inactive: raised surface token so the
// pill reads as elevation rather than a ghost. Hug-the-text .background() form —
// a bare Capsule in a ZStack is a greedy Shape and stretches in sparse tabs.)

func pillView(text: String, active: Bool) -> some View {
    Text(text)
        .font(.custom("Outfit", size: 10)).fontWeight(.bold)
        .tracking(0.6)
        .foregroundStyle(active ? cBright : cDim)
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
        .background(Capsule()
            .fill(active ? cBlue.opacity(0.16) : cSurface.opacity(0.85))
            .stroke(active ? cBlue.opacity(0.45) : cBorder.opacity(0.55), lineWidth: 1))
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
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    let f = Int(ctx.date.timeIntervalSinceReferenceDate * 10) % spinnerGlyphs.count
                    Text("\(spinnerGlyphs[f]) launching…")
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
        .contentShape(Rectangle())
        .allowsHitTesting(!loading)
        .onTapGesture { if !loading { action() } }
        .pointerCursor()
    }
}

// MARK: - Footer divider (border token, visible on both card gradient stops)

func dividerView() -> some View {
    Rectangle()
        .fill(cBorder.opacity(0.55))
        .frame(height: 1)
}
