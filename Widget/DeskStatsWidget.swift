import WidgetKit
import SwiftUI

// MARK: - Snapshot

/// Everything one widget refresh shows. Codable so the last snapshot can be cached.
struct Snapshot: Codable {
    var date = Date()
    var cpuTotal = 0.0, cpuUser = 0.0, cpuSystem = 0.0
    var perCore: [Double] = []
    var load: [Double] = [0, 0, 0]
    var memFraction = 0.0
    var memUsed: UInt64 = 0, memTotal: UInt64 = 0, memApp: UInt64 = 0
    var memWired: UInt64 = 0, memCompressed: UInt64 = 0, swapUsed: UInt64 = 0
    var memPressure = 1
    var netDown = 0.0, netUp = 0.0
    var diskTotal: UInt64 = 0, diskFree: UInt64 = 0
    var diskRead = 0.0, diskWrite = 0.0
    var batteryPercent: Int?
    var charging = false, onAC = true
    var uptime: TimeInterval = 0
    var thermal = 0
    // Recent history, oldest first (one point per refresh).
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var downHistory: [Double] = []
    var upHistory: [Double] = []

    var diskFraction: Double { diskTotal > 0 ? Double(diskTotal - min(diskFree, diskTotal)) / Double(diskTotal) : 0 }

    static let preview: Snapshot = {
        var s = Snapshot()
        s.cpuTotal = 0.23; s.cpuUser = 0.15; s.cpuSystem = 0.08
        s.perCore = [0.4, 0.3, 0.2, 0.25, 0.1, 0.05, 0.08, 0.12]
        s.load = [2.1, 1.8, 1.6]
        s.memFraction = 0.68; s.memUsed = 5_800_000_000; s.memTotal = 8_589_934_592
        s.memApp = 3_200_000_000; s.memWired = 1_400_000_000; s.memCompressed = 1_100_000_000
        s.netDown = 1_250_000; s.netUp = 84_000
        s.diskTotal = 245_000_000_000; s.diskFree = 49_000_000_000
        s.batteryPercent = 82; s.uptime = 3 * 86400 + 4 * 3600
        let xs: [Double] = (0..<24).map { Double($0) }
        s.cpuHistory = xs.map { (x: Double) -> Double in 0.15 + 0.12 * sin(x / 3) }
        s.memHistory = xs.map { (x: Double) -> Double in 0.62 + 0.04 * sin(x / 5) }
        s.downHistory = xs.map { (x: Double) -> Double in 600_000 + 500_000 * sin(x / 2) }
        s.upHistory = xs.map { (x: Double) -> Double in 80_000 + 40_000 * cos(x / 3) }
        return s
    }()
}

/// Takes a reading. CPU, network and disk rates need two samples, so this blocks for ~1 s.
enum Reader {
    private static let lock = NSLock()
    private static let historyLimit = 24
    private static let cacheKey = "lastSnapshot"

    static func read() -> Snapshot {
        lock.lock(); defer { lock.unlock() }

        let cpu = CPUSampler(), net = NetSampler(), io = DiskIOSampler()
        _ = cpu.sample(); _ = net.sample(); _ = io.sample()
        Thread.sleep(forTimeInterval: 1)
        let c = cpu.sample() ?? CPUSample()
        let n = net.sample()
        let d = io.sample()

        var s = Snapshot()
        s.cpuTotal = c.total; s.cpuUser = c.user; s.cpuSystem = c.system; s.perCore = c.perCore
        s.load = loadAverages()
        if let m = sampleMemory() {
            s.memFraction = m.fraction; s.memUsed = m.used; s.memTotal = m.total
            s.memApp = m.app; s.memWired = m.wired; s.memCompressed = m.compressed
            s.swapUsed = m.swapUsed; s.memPressure = m.pressure
        }
        s.netDown = n.down; s.netUp = n.up
        if let ds = sampleDiskSpace() { s.diskTotal = ds.total; s.diskFree = ds.free }
        s.diskRead = d.read; s.diskWrite = d.write
        if let b = sampleBattery() { s.batteryPercent = b.percent; s.charging = b.charging; s.onAC = b.onAC }
        s.uptime = systemUptime()
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue

        // Carry history forward from the previous reading. Several widgets refresh
        // together, so only add a point if the last one is more than 20 s old.
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cacheKey),
           let prev = try? JSONDecoder().decode(Snapshot.self, from: data) {
            s.cpuHistory = prev.cpuHistory; s.memHistory = prev.memHistory
            s.downHistory = prev.downHistory; s.upHistory = prev.upHistory
            if s.date.timeIntervalSince(prev.date) < 20, !prev.cpuHistory.isEmpty {
                return prev   // reuse the fresh one so all widgets agree
            }
        }
        func push(_ v: Double, _ a: inout [Double]) {
            a.append(v)
            if a.count > historyLimit { a.removeFirst(a.count - historyLimit) }
        }
        push(s.cpuTotal, &s.cpuHistory); push(s.memFraction, &s.memHistory)
        push(s.netDown, &s.downHistory); push(s.netUp, &s.upHistory)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: cacheKey) }
        return s
    }
}

// MARK: - Timeline

struct StatsEntry: TimelineEntry {
    var date: Date
    var snap: Snapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry { StatsEntry(date: .now, snap: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        DispatchQueue.global(qos: .utility).async {
            let s = Reader.read()
            completion(StatsEntry(date: s.date, snap: s))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let s = Reader.read()
            // Ask for a refresh in a minute; macOS decides how often it actually happens.
            completion(Timeline(entries: [StatsEntry(date: s.date, snap: s)],
                                policy: .after(Date().addingTimeInterval(60))))
        }
    }
}

// MARK: - Building blocks

private let track = Color.primary.opacity(0.1)

struct Header: View {
    let title: String, icon: String, tint: Color
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title.uppercased()).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            if let trailing { Text(trailing).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
        }
        .font(.system(size: 11, weight: .semibold))
    }
}

struct Spark: View {
    struct Series { var values: [Double]; var color: Color }
    var series: [Series]
    var maxValue: Double
    var body: some View {
        Canvas { ctx, size in
            let count = max(series.map(\.values.count).max() ?? 0, 2)
            let step = size.width / CGFloat(count - 1)
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
                ctx.fill(area, with: .linearGradient(Gradient(colors: [s.color.opacity(0.4), s.color.opacity(0.03)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct Ring: View {
    let fraction: Double, color: Color
    var lineWidth: CGFloat = 7
    var label: String? = nil
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label ?? fmtPercent(fraction))
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6).padding(lineWidth)
        }
        .padding(lineWidth / 2)   // keep the stroke inside the frame
    }
}

struct Big: View {
    let text: String
    var size: CGFloat = 30
    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.5)
    }
}

struct Dot: View {
    let color: Color, label: String, value: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
    }
}

struct Updated: View {
    let date: Date
    var body: some View {
        Text(date, style: .time).font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
    }
}

// MARK: - Widget views

struct CPUView: View {
    @Environment(\.widgetFamily) private var envFamily
    let s: Snapshot
    var wide = false
    private var family: WidgetFamily { wide ? .systemMedium : envFamily }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "CPU", icon: "cpu", tint: Tint.cpu,
                   trailing: family == .systemSmall ? nil : "Load " + s.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            if family == .systemSmall {
                Big(text: fmtPercent(s.cpuTotal))
                Spark(series: [.init(values: s.cpuHistory, color: Tint.cpu)], maxValue: 1)
                HStack { Dot(color: Tint.cpu, label: "Usr", value: fmtPercent(s.cpuUser))
                         Spacer(minLength: 2)
                         Dot(color: Tint.cpuSystem, label: "Sys", value: fmtPercent(s.cpuSystem)) }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Big(text: fmtPercent(s.cpuTotal))
                        Dot(color: Tint.cpu, label: "User", value: fmtPercent(s.cpuUser))
                        Dot(color: Tint.cpuSystem, label: "Sys", value: fmtPercent(s.cpuSystem))
                        Spacer(minLength: 0)
                        Updated(date: s.date)
                    }
                    .frame(width: 84, alignment: .leading)
                    VStack(spacing: 6) {
                        Spark(series: [.init(values: s.cpuHistory, color: Tint.cpu)], maxValue: 1)
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(Array(s.perCore.enumerated()), id: \.offset) { _, v in
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 2).fill(track)
                                    RoundedRectangle(cornerRadius: 2).fill(Tint.cpu)
                                        .frame(height: max(2, 16 * min(max(v, 0), 1)))
                                }
                            }
                        }
                        .frame(height: 16)
                    }
                }
            }
        }
    }
}

struct MemoryView: View {
    @Environment(\.widgetFamily) var family
    let s: Snapshot
    private var pressure: (String, Color) {
        switch s.memPressure {
        case 4: return ("Critical", Tint.cpuSystem)
        case 2: return ("High", Tint.disk)
        default: return ("Normal", Tint.cpu)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Memory", icon: "memorychip", tint: Tint.memory,
                   trailing: family == .systemSmall ? nil : "Swap " + fmtBytes(Double(s.swapUsed)))
            if family == .systemSmall {
                Big(text: fmtPercent(s.memFraction))
                Text("\(fmtBytes(Double(s.memUsed))) of \(fmtBytes(Double(s.memTotal)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Spark(series: [.init(values: s.memHistory, color: Tint.memory)], maxValue: 1)
                Dot(color: pressure.1, label: "Pressure", value: pressure.0)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Big(text: fmtPercent(s.memFraction))
                        Text("\(fmtBytes(Double(s.memUsed))) of \(fmtBytes(Double(s.memTotal)))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        Dot(color: pressure.1, label: "Pressure", value: pressure.0)
                        Spacer(minLength: 0)
                        Updated(date: s.date)
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Spark(series: [.init(values: s.memHistory, color: Tint.memory)], maxValue: 1)
                        HStack(spacing: 8) {
                            Dot(color: Tint.memory, label: "App", value: fmtBytes(Double(s.memApp)))
                            Dot(color: Tint.cpuSystem, label: "Wired", value: fmtBytes(Double(s.memWired)))
                            Dot(color: Tint.disk, label: "Compr", value: fmtBytes(Double(s.memCompressed)))
                        }
                    }
                }
            }
        }
    }
}

struct NetworkView: View {
    @Environment(\.widgetFamily) private var envFamily
    let s: Snapshot
    var wide = false
    private var family: WidgetFamily { wide ? .systemMedium : envFamily }
    var body: some View {
        let peak = max((s.downHistory + s.upHistory).max() ?? 0, 10 * 1024) * 1.1
        let graph = Spark(series: [.init(values: s.downHistory, color: Tint.down),
                                   .init(values: s.upHistory, color: Tint.up)], maxValue: peak)
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "Network", icon: "network", tint: Tint.down,
                   trailing: family == .systemSmall ? nil : "Peak " + fmtRate(peak / 1.1))
            if family == .systemSmall {
                rate("arrow.down", Tint.down, s.netDown)
                rate("arrow.up", Tint.up, s.netUp)
                graph
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        rate("arrow.down", Tint.down, s.netDown)
                        rate("arrow.up", Tint.up, s.netUp)
                        Spacer(minLength: 0)
                        Updated(date: s.date)
                    }
                    .frame(width: 110, alignment: .leading)
                    graph
                }
            }
        }
    }
    private func rate(_ icon: String, _ color: Color, _ v: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            Text(fmtRate(v)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

struct DiskView: View {
    let s: Snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Disk", icon: "internaldrive", tint: Tint.disk)
            HStack(spacing: 10) {
                Ring(fraction: s.diskFraction, color: Tint.disk).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fmtBytes(Double(s.diskFree), base: 1000))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("free of").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(fmtBytes(Double(s.diskTotal), base: 1000))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Dot(color: Tint.down, label: "Read", value: fmtRate(s.diskRead))
            Dot(color: Tint.up, label: "Write", value: fmtRate(s.diskWrite))
        }
    }
}

struct SystemView: View {
    let s: Snapshot
    private var thermal: (String, Color) {
        switch s.thermal {
        case 0: return ("Normal", Tint.cpu)
        case 1: return ("Warm", Tint.disk)
        case 2: return ("Hot", Tint.up)
        default: return ("Critical", Tint.cpuSystem)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "System", icon: "desktopcomputer", tint: Tint.system).padding(.bottom, 4)
            row("Uptime", fmtUptime(s.uptime))
            row("Cores", "\(s.perCore.count)")
            row("Thermal", thermal.0, thermal.1)
            if let b = s.batteryPercent {
                row(s.charging ? "Charging" : (s.onAC ? "On AC" : "Battery"), "\(b)%",
                    b <= 20 && !s.onAC ? Tint.cpuSystem : .primary)
            } else {
                row("Power", "AC")
            }
        }
    }
    private func row(_ label: String, _ value: String, _ color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit().foregroundStyle(color)
        }
        .font(.system(size: 12)).lineLimit(1).frame(maxHeight: .infinity)
    }
}

/// Everything at a glance: rings for small, rings + graphs for medium/large.
struct OverviewView: View {
    @Environment(\.widgetFamily) var family
    let s: Snapshot
    var body: some View {
        switch family {
        case .systemSmall:
            VStack(spacing: 8) {
                HStack(spacing: 8) { ring("CPU", s.cpuTotal, Tint.cpu); ring("MEM", s.memFraction, Tint.memory) }
                HStack(spacing: 8) { ring("DISK", s.diskFraction, Tint.disk); netStack }
            }
        case .systemMedium:
            HStack(spacing: 12) {
                ring("CPU", s.cpuTotal, Tint.cpu)
                ring("MEMORY", s.memFraction, Tint.memory)
                ring("DISK", s.diskFraction, Tint.disk)
                netStack.frame(maxWidth: .infinity)
            }
        default:
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ring("CPU", s.cpuTotal, Tint.cpu)
                    ring("MEMORY", s.memFraction, Tint.memory)
                    ring("DISK", s.diskFraction, Tint.disk)
                    netStack.frame(maxWidth: .infinity)
                }
                .frame(height: 96)
                Divider()
                CPUView(s: s, wide: true)
                Divider()
                NetworkView(s: s, wide: true)
            }
        }
    }
    private func ring(_ label: String, _ f: Double, _ c: Color) -> some View {
        VStack(spacing: 8) {
            Ring(fraction: f, color: c, lineWidth: 6)
            Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
    private var netStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(fmtRate(s.netDown)) } icon: { Image(systemName: "arrow.down").foregroundStyle(Tint.down) }
            Label { Text(fmtRate(s.netUp)) } icon: { Image(systemName: "arrow.up").foregroundStyle(Tint.up) }
            Updated(date: s.date)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

// MARK: - Widgets

func statConfig<V: View>(kind: String, name: String, summary: String, families: [WidgetFamily],
                         content: @escaping (Snapshot) -> V) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { entry in
        content(entry.snap)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(name)
    .description(summary)
    .supportedFamilies(families)
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        statConfig(kind: "overview", name: "Overview", summary: "CPU, memory, disk and network at a glance.",
                   families: [.systemSmall, .systemMedium, .systemLarge]) { OverviewView(s: $0) }
    }
}
struct CPUStatWidget: Widget {
    var body: some WidgetConfiguration {
        statConfig(kind: "cpu", name: "CPU", summary: "Processor usage and history.",
                   families: [.systemSmall, .systemMedium]) { CPUView(s: $0) }
    }
}
struct MemoryStatWidget: Widget {
    var body: some WidgetConfiguration {
        statConfig(kind: "memory", name: "Memory", summary: "Memory usage and pressure.",
                   families: [.systemSmall, .systemMedium]) { MemoryView(s: $0) }
    }
}
struct NetworkStatWidget: Widget {
    var body: some WidgetConfiguration {
        statConfig(kind: "network", name: "Network", summary: "Download and upload speed.",
                   families: [.systemSmall, .systemMedium]) { NetworkView(s: $0) }
    }
}
struct DiskStatWidget: Widget {
    var body: some WidgetConfiguration {
        statConfig(kind: "disk", name: "Disk", summary: "Free space and disk activity.",
                   families: [.systemSmall]) { DiskView(s: $0) }
    }
}
struct SystemStatWidget: Widget {
    var body: some WidgetConfiguration {
        statConfig(kind: "system", name: "System", summary: "Uptime, thermal state and battery.",
                   families: [.systemSmall]) { SystemView(s: $0) }
    }
}

@main
struct DeskStatsWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        CPUStatWidget()
        MemoryStatWidget()
        NetworkStatWidget()
        DiskStatWidget()
        SystemStatWidget()
    }
}
