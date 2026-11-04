import SwiftUI

// MARK: - Payload model
// Every field is optional so a partial or renamed payload still renders; a
// failed top-level decode is the "server down" branch (mirrors the JSX
// `try { JSON.parse } catch {}` guard).

struct Loose: Decodable {
    let display: String
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let s = try? box.decode(String.self) {
            display = s
            return
        }
        if let d = try? box.decode(Double.self) {
            let r = d.rounded()
            display = d == r ? String(Int64(r)) : String(d)
            return
        }
        if let i = try? box.decode(Int.self) {
            display = String(i)
            return
        }
        if let b = try? box.decode(Bool.self) {
            display = b ? "true" : "false"
            return
        }
        display = ""
    }
}

struct Engine: Decodable {
    let model: String?
    let context: Double?
    let kv: Loose?
    let version: Loose?
    let vram_free_mib: Double?
}

struct Live: Decodable {
    let state: String?
    let phase: String?
    let queued: Double?
    let prompt_tokens: Double?
    let prompt_read: Double?
    let prompt_total: Double?
    let generated: Double?
    let max_tokens: Double?
    let elapsed_s: Double?
    let tok_s: Double?
    let tok_s_mean: Double?
    let tok_s_window_s: Double?
    let prefill_tok_s_mean: Double?
}

struct Hardware: Decodable {
    let gpu_util: Double?
    let gpu_mem_used: Double?
    let gpu_mem_total: Double?
    let gpu_temp: Double?
    let gpu_power: Double?
    let gpu_power_limit: Double?
    let cpu: Double?
    let ram_used: Double?
    let ram_total: Double?
    let disk_read_mb: Double?
    let disk_write_mb: Double?
    let tok_s: Double?
    let tok_s_mean: Double?
    let prefill_tok_s_mean: Double?
}

struct HardwareStatic: Decodable {
    let gpu_name: String?
    let gpu_count: Double?
    let cpu_name: String?
    let cores: Double?
    let threads: Double?
}

struct History: Decodable {
    // JSON nulls inside the arrays decode as nil elements, like the JSX's
    // `.filter(v => v !== null)` downstream.
    let tok_s: [Double?]?
    let gpu_util: [Double?]?
    let gpu_mem_used: [Double?]?
    let gpu_temp: [Double?]?
    let gpu_power: [Double?]?
    let gpu_pcie_rx_mb: [Double?]?
    let cpu: [Double?]?
    let ram_used: [Double?]?
    let disk_read_mb: [Double?]?
}

struct Request: Decodable {
    let time: Double?
    let finish: String?
    let output_tokens: Double?
    let prompt_tokens: Double?
    let reused: Double?
    let prompt_ms: Double?
    let decode_tok_s: Double?
    let hit_rate: Double?
    let drafts_offered: Double?
    let drafts_accepted: Double?
}

struct MetricsPayload: Decodable {
    let engine: Engine?
    let live: Live?
    let hardware: Hardware?
    let hardware_static: HardwareStatic?
    let history: History?
    let requests: [Request]?
    let time: Double?
}

// MARK: - Formatter ports (JSX `f()` and `n()`)

// f(v, d): "–" for null/undefined, else fixed `d` decimals. NaN/Inf render as
// "–" (JS would print "NaN" — we prefer the dash).
func fmtFixed(_ v: Double?, digits d: Int = 1) -> String {
    guard let v, v.isFinite else { return "\u{2013}" } // en dash
    return String(format: "%.*f", d, v)
}

// n(v): toLocaleString for integral values — group the integer part with
// thousands separators, drop a zero fraction.
func fmtGrouped(_ v: Double?) -> String {
    guard let v, v.isFinite else { return "\u{2013}" }
    let rounded = v.rounded()
    let whole = Int64(rounded == v ? rounded : v)
    let digits = String(abs(whole))
    var grouped = ""
    for (i, ch) in digits.reversed().enumerated() {
        if i > 0 && i % 3 == 0 { grouped.insert(contentsOf: ",", at: grouped.startIndex) }
        grouped.insert(ch, at: grouped.startIndex)
    }
    let sign = whole < 0 ? "-" : ""
    if rounded != v {
        let frac = abs(v) - Double(abs(whole))
        let fracStr = String(format: "%.1f", frac).dropFirst() // ".x"
        return sign + grouped + fracStr
    }
    return sign + grouped
}

// JSX `Math.min(Math.max(v, mn), mx)` used by Spark/Bar.
func clamped(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(v, lo), hi)
}
