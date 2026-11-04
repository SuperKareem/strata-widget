# Design System Master File

> **LOGIC:** When building a specific page, first check `design-system/pages/[page-name].md`.
> If that file exists, its rules **override** this Master file.
> If not, strictly follow the rules below.

---

**Project:** Strata Widget
**Generated:** 2026-10-14 20:24:35 · **Reconciled to the widget:** 2026-11-04
**Category:** Developer Tool / IDE
**Design Dials:** Density 8/10 (Dense / Dashboard)

**Two surfaces, two token sets.** This repo holds the SwiftUI desktop widget
(`swift-widget/`) and, soon, a control server. The widget is skinned to the
**Strata UI / Gainsty** tokens of the web app at `:8080` (`web/tokens.css`,
dark theme) — that is the **authoritative** set below. The originally generated
Tailwind system (Inter + slate palette + solid green buttons) is kept only as a
**legacy web** reference; it does **not** apply to the widget.

---

## Global Rules — Widget (authoritative)

### Color Palette — Strata UI dark tokens

Defined in `swift-widget/components.swift` (`cBlue`, `cRed`, … via `hex(_:)`).
The widget always renders the dark theme, so the dark values are inlined.

| Token | Hex | Swift constant | Role |
|-------|-----|----------------|------|
| `st-bg` | `#0e1113` | — (gradient stop) | Card gradient end, OLED base |
| `st-surface` | `#161a1d` | — (gradient stop) | Card gradient start |
| `st-surface-2` | `#1d2226` | `cSurface` | Raised surface: inactive pills, model rows, field fills |
| `st-line` | `#2a3036` | `cBorder` | Hairlines, dividers, capsule strokes (used at 0.55 opacity) |
| `st-ink` | `#eef1f3` | `cText` / `cStrong` / `cBright` | Container text, values, active pill text |
| `st-ink-muted` | `#8e979f` | `cMuted` / `cDim` | Labels/keys, inactive pills, footer |
| `st-accent` | `#34d399` | `cBlue` / `cGreen` | Data, active tab, progress, focus ring, running/idle |
| `st-danger` | `#ff5a6e` | `cRed` | Stop / server down / utilization >90% |
| `st-warn` | `#f5b53d` | `cAmber` | Starting / queued / utilization >75% |
| — (no web token) | `#fb923c` | `cOrange` | GPU temp only. Kept; has no Gainsty equivalent |
| — (no web token) | `#c084fc` | `cPurple` | GPU power only. Kept; has no Gainsty equivalent |
| — | `#ffffff` | `cWhite` | Bar-track fill at 0.07 only |

**Notes**
- The historical name `cBlue` is an artifact of the original blue accent; it holds
  **`st-accent` green**. Treat `cBlue`/`cGreen` as one token, not two colors.
- **Focus ring:** the legacy `Ring` token (`#FFFFFF`) is *not* used — a white halo
  sits too close to `st-ink`. Focus states use `st-accent` at 0.75 opacity with a
  1.5px stroke (`fieldStroke` in `strata-app.swift`).
- Utilization ramp: `>90 → st-danger`, `>75 → st-warn`, else `st-accent` (`utilColor`).

### Typography

- **UI face:** **Outfit** (variable, SIL OFL 1.1) — `.font(.custom("Outfit", size:)).weight(...)`
  at 8–13px with 0.4–1.2 tracking. Source: `swift-widget/fonts/Outfit.ttf`.
- **Data face:** **SF Mono** — every numeric readout, `.font(.system(size:, design: .monospaced))`,
  tabular numerals. Matches the design system's "technical/precision, data as mono" mood.
- **No Google Fonts.** A bundled `.app` cannot `@import`; the face must be installed on
  the machine or bundled into the bundle.
- ⚠️ **Known gap:** `build.sh` does **not** copy `Outfit.ttf` into `StrataWidget.app`, so
  `.custom("Outfit")` silently falls back to the system UI face on a machine without
  Outfit installed. Font fidelity currently depends on the host, not the build.

### Spacing

*Density: 8/10 — Dense / Dashboard.* The widget's real rhythm (from
`components.swift` / `strata-app.swift`) rather than the generated rem scale:

| Token | Value | Usage |
|-------|-------|-------|
| `--space-xs` | `2px` | Pill vertical padding (3px is the floor), tightest inline gaps |
| `--space-sm` | `3–5px` | Pill padding, model-row padding, kv gaps |
| `--space-md` | `6–8px` | Row/column gaps, button padding (6 vertical), dialog spacing |
| `--space-lg` | `9–10px` | Metric-row gaps, pill horizontal padding, hairline label gaps |
| `--space-xl` | `16px` | Card padding, section head top, control-block top |
| `--space-2xl` | `20px` | Dialog padding |
| `--space-3xl` | `24px`+ | Not used by the widget |

Card is `350 × 640` (`windowIdealPlacement`); the live slot is pinned to `52px`
height so the card never resizes between idle and reading states.

### Motion

| Token | Value | Usage |
|-------|-------|-------|
| `--motion` | `ease-out 200ms` | Every state change: bar fill, pill active state, status color, hover, focus |
| Reduced motion | transitions removed | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; the 10 Hz spinner becomes static |

`motion` (in `components.swift`) is the single animation source and returns `nil`
under reduced motion, so `.animation(motion, value:)` and `withAnimation(motion)`
become no-ops. Keep every new transition inside 150–300ms.

### Shadow / depth

| Depth | Value | Usage |
|-------|-------|-------|
| Card elevation | 1px `st-line` @0.55 stroke + `st-surface → st-bg` gradient at ~165° | **No box shadow.** Depth reads as stroke + gradient, not shadow |
| Bar glow | `color.opacity(0.25)` / radius `3` | The only glow in the widget (JSX original was 0.33 / 4; trimmed for "low white emission") |
| Raised surface | `st-surface-2` @0.85 fill | Inactive pills/rows read as elevation rather than ghost |

---

## Component Specs — Widget (SwiftUI)

| Component | Spec |
|-----------|------|
| **Card** | radius 16, padding 16 (top/bottom/horizontal), gradient `#161a1d@0.94 → #0e1113@0.96`, 1px `st-line@0.55` stroke, no shadow. Window: level `-1`, all Spaces, stationary, movable by background, `LSUIElement` |
| **Tab pill** | Outfit 10 bold, tracking 0.6, padding 3×10, **Capsule**. Active: `st-accent@0.16` fill + `st-accent@0.45` stroke + `st-ink` text. Inactive: `st-surface-2@0.85` fill + `st-line@0.55` stroke + `st-ink-muted` text. Hover: `hoverLift()` |
| **Status pill** | Outfit 10 semibold, padding 3×9, Capsule, status color at 0.12 fill / 0.30 stroke, status-colored text. Not clickable |
| **Control button** (`ControlButton`) | Outfit 11 semibold, tracking 0.5, padding 6×18, `minWidth: 90`, Capsule, **ghost/tint**: `color@0.10` fill + `color@0.45` stroke + colored text. Hover: `hoverLift(color, 0.08, 0.8)`. Loading: opacity 0.7, hit-testing off, spinner glyph + "launching…" (static under reduced motion) |
| **Metric row** | grid `52px label · 92px sparkline · 1fr value`, gap 9. Label Outfit 11 muted; value SF Mono 11 `st-ink`; sparkline 92×18 area gradient 0.30 → 0.02, stroke 1.5 round |
| **KV pair** | space-between; key Outfit 11 muted, value SF Mono 11 `st-ink` |
| **Bar** | 5px Capsule track `white@0.07`, fill Capsule with leading→trailing gradient `color@0.47 → color`, width animated on `--motion` |
| **Section head** | 3×10 accent tick + Outfit 10 semibold uppercase tracking 1.2 in `st-ink-muted`, hairline rule to the right edge, 16/8 vertical rhythm |
| **Model row** | Capsule `st-surface-2@0.5` fill + `st-line@0.55` stroke, padding 5×10; Launch button omitted for the model already running |
| **Field / capsule** | SF Mono 11, `.textFieldStyle(.plain)`, padding 6×8–10, `st-surface-2@0.85` fill, Capsule stroke `st-line@0.55` @1px. **Focused:** `st-accent@0.75` @1.5px |
| **Dialog** | dark, `.padding(20)`, own `NSWindow` (titled + closable) because the card window has a hidden title bar and never becomes key |
| **Divider** | `st-line@0.55`, 1px |

**Hover state.** A pointer cursor alone is not a visible state change. All clickables
carry `pointerCursor()` **and** `hoverLift()` — a low-opacity tinted fill plus a
brighter capsule stroke drawn inside the control's existing bounds, so no layout
shifts. Non-clickable capsules (`portCapsule`, `serverURLButton`, model rows) get
neither; `serverURLButton` is a deliberate no-op button kept for layout parity.

**Shape rule.** Everything non-card is a **Capsule**. The legacy 8/12/16px radii
apply only to the web surface.

---

## Legacy web specs (Tailwind — NOT for the widget)

Kept for the web app only. Values below contradict the widget and the OLED rule
(e.g. light-mode input borders, `background: white` modals, solid `#22C55E`
buttons) and must never be applied to `swift-widget/`.

```css
/* Palette (legacy web): primary #1E293B · secondary #334155 · accent #22C55E
   bg #0F172A · fg #F8FAFC · card #1B2336 · muted #94A3B8 · border #475569
   destructive #EF4444 · ring #FFFFFF */

/* Typography (legacy web) */
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');

/* Spacing (legacy web): 2 / 4 / 8 / 12 / 16 / 24 / 32 */
/* Shadows (legacy web): 0 1px 2px .05 · 0 4px 6px .1 · 0 10px 15px .1 · 0 20px 25px .15 */

.btn-primary   { background:#22C55E; color:#0F172A; padding:12px 24px; border-radius:8px; font-weight:600; transition:all 200ms ease; cursor:pointer; }
.btn-secondary { background:transparent; color:#F8FAFC; border:2px solid #1E293B; padding:12px 24px; border-radius:8px; font-weight:600; transition:all 200ms ease; cursor:pointer; }
.card          { background:#0F172A; border-radius:12px; padding:24px; box-shadow:var(--shadow-md); transition:all 200ms ease; cursor:pointer; }
.input         { padding:12px 16px; border:1px solid #E2E8F0; border-radius:8px; font-size:16px; transition:border-color 200ms ease; }
.input:focus   { border-color:#1E293B; outline:none; box-shadow:0 0 0 3px #1E293B20; }
.modal-overlay { background:rgba(0,0,0,.5); backdrop-filter:blur(4px); }
.modal         { background:white; border-radius:16px; padding:32px; box-shadow:var(--shadow-xl); max-width:500px; width:90%; }
```

---

## Style Guidelines

**Style:** Dark Mode (OLED) — dark-only; there is no light branch in the widget.

**Keywords:** Dark theme, low light, high contrast, deep black, midnight blue, eye-friendly, OLED, night mode, power efficient

**Key Effects:** Minimal glow (`barView` only), dark-to-light transitions, low white
emission, high readability, visible focus. Contrast is verified against the card
gradient: `st-ink-muted` on `#161a1d` ≈ 5.8:1 and on `#0e1113` ≈ 6.4:1; `st-ink` far higher.

**Mood:** dark, cinematic, technical, precision, clean, premium, developer, professional, high-end utility

### Page Pattern

**Pattern Name:** FAQ/Documentation Landing *(web-only reference)*

- **Conversion Strategy:** Reduce support tickets. Track search analytics. Show related articles. Contact escalation path.
- **CTA Placement:** Search bar prominent + Contact CTA for unresolved questions
- **Section Order:** Hero with search bar > Popular categories > FAQ accordion > Contact/support CTA

---

## Anti-Patterns (Do NOT Use)

- ❌ Light mode default
- ❌ Slow performance
- ❌ **Emojis as icons** — Use SVG icons (Heroicons, Lucide, Simple Icons); SF Symbols on macOS
- ❌ **Missing cursor:pointer** — All clickable elements must have `pointerCursor()`
- ❌ **Layout-shifting hovers** — No scale/translate transforms; hover changes fill/stroke only (`hoverLift`)
- ❌ **Low contrast text** — Maintain 4.5:1 minimum contrast ratio
- ❌ **Instant state changes** — Every state change goes through `motion` (150–300ms)
- ❌ **Invisible focus states** — Fields show the accent stroke when focused (`fieldStroke`)
- ❌ **Solid `#22C55E` buttons / 8px radii / box-shadow cards** — widget-only: ghost capsules
- ❌ **Google Fonts `@import`** — meaningless in a bundled `.app`; see the Outfit caveat

**Known deviation:** status (`●`) and loading (`⠋⠙⠹…`) are typographic glyphs ported
from the JSX, not an icon set. They satisfy "no emojis as icons" but not "one
consistent icon set"; SF Symbols would be the compliant replacement and are not yet used.

---

## Pre-Delivery Checklist

### Widget (SwiftUI)

- [ ] Token values match `components.swift` (Gainsty dark set), not the legacy table
- [ ] UI text is Outfit, numeric readouts SF Mono
- [ ] Every clickable has `pointerCursor()` **and** a visual hover state
- [ ] Every state change transitions on `motion` (150–300ms), never instantly
- [ ] Reduced motion honoured: no transitions, static spinner
- [ ] Focus states visible on dialog fields (accent stroke)
- [ ] Card depth from stroke + gradient only — no shadow, no glow except the bar
- [ ] Text contrast ≥ 4.5:1 against both gradient stops
- [ ] No layout shift on hover; card height stable (live slot pinned to 52px)
- [ ] `./build.sh` from `swift-widget/` builds and signs clean
- [ ] ⚠️ Not yet satisfied: font is not bundled into `StrataWidget.app`

### Web (legacy Tailwind)

- [ ] No emojis used as icons (use SVG instead)
- [ ] All icons from consistent icon set (Heroicons/Lucide)
- [ ] `cursor-pointer` on all clickable elements
- [ ] Hover states with smooth transitions (150-300ms)
- [ ] Light mode: text contrast 4.5:1 minimum
- [ ] Focus states visible for keyboard navigation
- [ ] `prefers-reduced-motion` respected
- [ ] Responsive: 375px, 768px, 1024px, 1440px
- [ ] No content hidden behind fixed navbars
- [ ] No horizontal scroll on mobile

---

## Repo Layout

- `swift-widget/` — widget sources (`strata-app.swift`, `components.swift`,
  `payload.swift`), `fonts/Outfit.ttf`, `build.sh`, built `StrataWidget.app`.
- `design-system/` — shared at the repo root on purpose: it governs the widget now
  and the control server next, so it must not move under `swift-widget/`.
- The control server (upcoming sibling folder) should reuse the Gainsty dark tokens
  above rather than the legacy web table.
