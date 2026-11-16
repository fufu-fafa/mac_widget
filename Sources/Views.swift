import SwiftUI

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(height: 14)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Scrolling area graph; newest sample at the right edge.
struct LineGraph: View {
    struct Series {
        var values: [Double]
        var color: Color
    }
    var series: [Series]
    var maxValue: Double

    var body: some View {
        Canvas { ctx, size in
            for f in [0.25, 0.5, 0.75] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height * f))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
                ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            let step = size.width / CGFloat(Stats.capacity - 1)
            let scale = max(maxValue, .leastNonzeroMagnitude)
            for s in series where s.values.count > 1 {
                let n = s.values.count
                var line = Path()
                for (i, v) in s.values.enumerated() {
                    let pt = CGPoint(x: size.width - CGFloat(n - 1 - i) * step,
                                     y: size.height - 1 - CGFloat(min(max(v / scale, 0), 1)) * (size.height - 3))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: size.width - CGFloat(n - 1) * step, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [s.color.opacity(0.42), s.color.opacity(0.03)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct BigValue: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }
}

struct HBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Tint.track)
                Capsule().fill(color).frame(width: max(3, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Widgets

struct CPUWidget: View {
    @ObservedObject var stats: Stats

    var body: some View {
        Card(title: "CPU", icon: "cpu", tint: Tint.cpu,
             trailing: "Load " + stats.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    BigValue(text: fmtPercent(stats.cpu.total))
                    LegendDot(color: Tint.cpu, label: "User", value: fmtPercent(stats.cpu.user))
                    LegendDot(color: Tint.cpuSystem, label: "Sys", value: fmtPercent(stats.cpu.system))
                }
                .frame(width: 84, alignment: .leading)
                LineGraph(series: [.init(values: stats.cpuHistory, color: Tint.cpu),
                                   .init(values: stats.cpuSystemHistory, color: Tint.cpuSystem)],
                          maxValue: 1)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(stats.cpu.perCore.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Tint.track)
                        RoundedRectangle(cornerRadius: 2).fill(Tint.cpu)
                            .frame(height: max(2, 18 * min(max(v, 0), 1)))
                    }
                }
            }
            .frame(height: 18)
        }
    }
}

struct MemoryWidget: View {
    @ObservedObject var stats: Stats

    private var pressure: (String, Color) {
        switch stats.mem?.pressure ?? 1 {
        case 4: return ("Pressure critical", Tint.cpuSystem)
        case 2: return ("Pressure high", Tint.disk)
        default: return ("Pressure normal", Tint.cpu)
        }
    }

    var body: some View {
        let m = stats.mem
        Card(title: "Memory", icon: "memorychip", tint: Tint.memory,
             trailing: "Swap " + fmtBytes(Double(m?.swapUsed ?? 0))) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    BigValue(text: fmtPercent(m?.fraction ?? 0))
                    Text("\(fmtBytes(Double(m?.used ?? 0))) of \(fmtBytes(Double(m?.total ?? 0)))")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Circle().fill(pressure.1).frame(width: 6, height: 6)
                        Text(pressure.0).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 104, alignment: .leading)
                LineGraph(series: [.init(values: stats.memHistory, color: Tint.memory)], maxValue: 1)
            }
            HStack(spacing: 10) {
                LegendDot(color: Tint.memory, label: "App", value: fmtBytes(Double(m?.app ?? 0)))
                LegendDot(color: Tint.cpuSystem, label: "Wired", value: fmtBytes(Double(m?.wired ?? 0)))
                LegendDot(color: Tint.disk, label: "Compr", value: fmtBytes(Double(m?.compressed ?? 0)))
                Spacer(minLength: 0)
            }
            .frame(height: 18)
        }
    }
}

struct NetworkWidget: View {
    @ObservedObject var stats: Stats

    var body: some View {
        let peak = max((stats.downHistory + stats.upHistory).max() ?? 0, 10 * 1024)
        Card(title: "Network", icon: "network", tint: Tint.down, trailing: "Peak " + fmtRate(peak)) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    rate(icon: "arrow.down", color: Tint.down, value: stats.netDown)
                    rate(icon: "arrow.up", color: Tint.up, value: stats.netUp)
                }
                .frame(width: 104, alignment: .leading)
                LineGraph(series: [.init(values: stats.downHistory, color: Tint.down),
                                   .init(values: stats.upHistory, color: Tint.up)],
                          maxValue: peak * 1.1)
            }
            HStack(spacing: 10) {
                LegendDot(color: Tint.down, label: "Received", value: fmtBytes(Double(stats.netTotalDown)))
                LegendDot(color: Tint.up, label: "Sent", value: fmtBytes(Double(stats.netTotalUp)))
                Spacer(minLength: 0)
            }
            .frame(height: 18)
        }
    }

    private func rate(icon: String, color: Color, value: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            Text(fmtRate(value)).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct ProcessesWidget: View {
    @ObservedObject var stats: Stats

    var body: some View {
        Card(title: "Top Processes", icon: "list.bullet", tint: Tint.cpu, trailing: "CPU      Memory") {
            VStack(spacing: 0) {
                ForEach(stats.procs) { p in
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                            .frame(width: 120, alignment: .leading)
                        HBar(fraction: p.cpu / 100, color: Tint.cpu)
                        Text(String(format: "%.1f%%", p.cpu)).frame(width: 46, alignment: .trailing)
                        Text(fmtBytes(Double(p.memBytes))).foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .font(.system(size: 11)).monospacedDigit()
                    .frame(maxHeight: .infinity)
                }
                if stats.procs.isEmpty {
                    Text("Sampling…").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct DiskWidget: View {
    @ObservedObject var stats: Stats

    var body: some View {
        let d = stats.disk
        Card(title: "Disk", icon: "internaldrive", tint: Tint.disk) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Tint.track, lineWidth: 7)
                    Circle().trim(from: 0, to: d?.fraction ?? 0)
                        .stroke(Tint.disk, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(fmtPercent(d?.fraction ?? 0))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fmtBytes(Double(d?.free ?? 0), base: 1000))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("free of").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text(fmtBytes(Double(d?.total ?? 0), base: 1000))
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                LegendDot(color: Tint.down, label: "Read", value: fmtRate(stats.diskRead))
                LegendDot(color: Tint.up, label: "Write", value: fmtRate(stats.diskWrite))
            }
        }
    }
}

struct SystemWidget: View {
    @ObservedObject var stats: Stats

    private var thermal: (String, Color) {
        switch stats.thermal {
        case .nominal: return ("Normal", Tint.cpu)
        case .fair: return ("Warm", Tint.disk)
        case .serious: return ("Hot", Tint.up)
        case .critical: return ("Critical", Tint.cpuSystem)
        @unknown default: return ("–", .secondary)
        }
    }

    var body: some View {
        Card(title: "System", icon: "desktopcomputer", tint: Tint.system) {
            VStack(spacing: 0) {
                row("Uptime", fmtUptime(stats.uptime))
                row("Cores", "\(stats.cpu.perCore.count)")
                row("Thermal", thermal.0, color: thermal.1)
                if let b = stats.battery {
                    row(b.charging ? "Charging" : (b.onAC ? "On AC" : "Battery"), "\(b.percent)%",
                        color: b.percent <= 20 && !b.onAC ? Tint.cpuSystem : .primary)
                } else {
                    row("Power", "AC")
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit().foregroundStyle(color)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxHeight: .infinity)
    }
}
