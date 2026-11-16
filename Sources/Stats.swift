import Foundation
import Combine

/// Samples everything on a timer and publishes it for the widgets.
final class Stats: ObservableObject {
    static let capacity = 60   // samples kept per graph

    @Published var cpu = CPUSample()
    @Published var cpuHistory: [Double] = []
    @Published var cpuSystemHistory: [Double] = []
    @Published var load: [Double] = [0, 0, 0]

    @Published var mem: MemSample?
    @Published var memHistory: [Double] = []

    @Published var netDown = 0.0
    @Published var netUp = 0.0
    @Published var downHistory: [Double] = []
    @Published var upHistory: [Double] = []
    @Published var netTotalDown: UInt64 = 0
    @Published var netTotalUp: UInt64 = 0

    @Published var disk: DiskSpace?
    @Published var diskRead = 0.0
    @Published var diskWrite = 0.0

    @Published var procs: [ProcInfo] = []

    @Published var battery: BatteryInfo?
    @Published var uptime: TimeInterval = 0
    @Published var thermal: ProcessInfo.ThermalState = .nominal

    private let cpuSampler = CPUSampler()
    private let netSampler = NetSampler()
    private let diskIO = DiskIOSampler()
    private let procQueue = DispatchQueue(label: "deskstats.ps", qos: .utility)
    private var procBusy = false
    private var timer: Timer?
    private var tick = 0

    private(set) var interval: TimeInterval = 1

    func start(interval: TimeInterval) {
        self.interval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)   // keep updating while a widget is dragged
        timer = t
        update()
    }

    private func push(_ v: Double, into a: inout [Double]) {
        a.append(v)
        if a.count > Self.capacity { a.removeFirst(a.count - Self.capacity) }
    }

    private func update() {
        defer { tick += 1 }

        if let c = cpuSampler.sample() {
            cpu = c
            push(c.total, into: &cpuHistory)
            push(c.system, into: &cpuSystemHistory)
        }
        load = loadAverages()

        if let m = sampleMemory() {
            mem = m
            push(m.fraction, into: &memHistory)
        }

        let n = netSampler.sample()
        netDown = n.down; netUp = n.up
        push(n.down, into: &downHistory)
        push(n.up, into: &upHistory)
        netTotalDown = netSampler.totalDown
        netTotalUp = netSampler.totalUp

        let io = diskIO.sample()
        diskRead = io.read; diskWrite = io.write

        // Slower-moving values.
        let every = { (seconds: Double) in self.tick % max(1, Int(seconds / self.interval)) == 0 }
        if every(30) { disk = sampleDiskSpace() }
        if every(10) {
            battery = sampleBattery()
            uptime = systemUptime()
            thermal = ProcessInfo.processInfo.thermalState
        }
        if every(3), !procBusy {
            procBusy = true
            procQueue.async { [weak self] in
                let top = sampleTopProcesses(limit: 5)
                DispatchQueue.main.async {
                    self?.procs = top
                    self?.procBusy = false
                }
            }
        }
    }
}
