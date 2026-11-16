import SwiftUI

// MARK: - Formatting

func fmtBytes(_ bytes: Double, base: Double = 1024) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = max(bytes, 0)
    var i = 0
    while v >= base && i < units.count - 1 { v /= base; i += 1 }
    let digits = (i == 0 || v >= 100) ? 0 : (v >= 10 ? 1 : 2)
    return String(format: "%.\(digits)f %@", v, units[i])
}

func fmtRate(_ bytesPerSec: Double) -> String { fmtBytes(bytesPerSec) + "/s" }

func fmtPercent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

func fmtUptime(_ t: TimeInterval) -> String {
    let m = Int(t) / 60, h = m / 60, d = h / 24
    if d > 0 { return "\(d)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m % 60)m" }
    return "\(m)m"
}

// MARK: - Palette

enum Tint {
    static let cpu = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let cpuSystem = Color(red: 0.98, green: 0.45, blue: 0.42)
    static let memory = Color(red: 0.55, green: 0.60, blue: 1.00)
    static let down = Color(red: 0.30, green: 0.78, blue: 1.00)
    static let up = Color(red: 1.00, green: 0.62, blue: 0.30)
    static let disk = Color(red: 0.98, green: 0.80, blue: 0.32)
    static let system = Color(red: 0.80, green: 0.56, blue: 1.00)
    static let track = Color.white.opacity(0.09)
}
