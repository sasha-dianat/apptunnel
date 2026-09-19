// Telemetry.swift — the ten live health bands and the snapshot reader.
//
// Values are 0.0...1.0, or -1.0 for "unknown", which renders grey and never
// red: an unmeasured band must not look like a failing one.

import Foundation
import Darwin

struct Band {
    let key: String
    let label: String
    let hz: String          // the Winamp band this replaces, for the scale strip
    let idleIsFine: Bool    // zero is normal, not an alarm (FLOW only)
}

let BANDS: [Band] = [
    Band(key: "link",   label: "LINK",   hz: "60",  idleIsFine: false),
    Band(key: "dns",    label: "DNS",    hz: "170", idleIsFine: false),
    Band(key: "socks",  label: "SOCKS",  hz: "310", idleIsFine: false),
    Band(key: "bridge", label: "BRIDGE", hz: "600", idleIsFine: false),
    Band(key: "exit",   label: "EXIT",   hz: "1K",  idleIsFine: false),
    Band(key: "rtt",    label: "RTT",    hz: "3K",  idleIsFine: false),
    Band(key: "flow",   label: "FLOW",   hz: "6K",  idleIsFine: true),
    Band(key: "seal",   label: "SEAL",   hz: "12K", idleIsFine: false),
    Band(key: "wall",   label: "WALL",   hz: "14K", idleIsFine: false),
    Band(key: "grip",   label: "GRIP",   hz: "16K", idleIsFine: false),
]

final class TelemetryStore {
    private(set) var values  = [Double](repeating: -1, count: BANDS.count)
    private(set) var details = [String](repeating: "", count: BANDS.count)
    private(set) var score: Double = -1
    private(set) var exitIP = ""
    private(set) var history: [Double] = []     // last 120 rtt samples
    private(set) var fresh = false              // a sample arrived in the last 60s

    private let path = NSHomeDirectory() + "/.apptunnel/telemetry.json"
    private var lastStamp: Double = 0

    /// Returns true when anything changed and the UI should redraw.
    func poll() -> Bool {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["t"] as? Double else {
            if fresh || score >= 0 {
                values = [Double](repeating: -1, count: BANDS.count)
                details = [String](repeating: "", count: BANDS.count)
                score = -1; fresh = false; exitIP = ""
                return true
            }
            return false
        }
        let age = Date().timeIntervalSince1970 - t
        let nowFresh = age < 60
        if t == lastStamp && nowFresh == fresh { return false }
        lastStamp = t
        fresh = nowFresh

        let detail = (o["detail"] as? [String: Any]) ?? [:]
        for (i, b) in BANDS.enumerated() {
            values[i]  = (o[b.key] as? Double) ?? -1
            details[i] = (detail[b.key] as? String) ?? ""
        }
        score = (o["score"] as? Double) ?? -1
        exitIP = (o["exit_ip"] as? String) ?? ""

        if let rtt = o["rtt"] as? Double, rtt >= 0 {
            history.append(rtt)
            if history.count > 120 { history.removeFirst(history.count - 120) }
        }
        return true
    }
}


/// Real throughput, measured by the app itself.
///
/// The launcher's FLOW band counts established connections, which barely moves
/// while bytes are flying — so the display could not react to bandwidth. This
/// reads the kernel's per-interface byte counters directly through getifaddrs
/// (no subprocess, no privileges) and turns the delta into a rate.
///
/// All interfaces are summed on purpose: tunnelled traffic crosses lo0 on its
/// way to the local bridge, so loopback is where the tunnel's own load shows up.
final class ThroughputMeter {
    /// 0.0 idle … 1.0 at roughly 4 MB/s, log-scaled so ordinary browsing is
    /// visible rather than crushed against the floor.
    private(set) var level: Double = 0
    private(set) var bytesPerSecond: Double = 0
    /// Set by the snapshot modes so a render can show a chosen load.
    var pinned: Double? = nil { didSet { if let v = pinned { level = v } } }

    // Separated by direction, because a bandwidth graph that sums them cannot
    // show the asymmetry that actually characterises a link - a download and an
    // upload of the same size are the same line.
    private(set) var inBytesPerSecond: Double = 0
    private(set) var outBytesPerSecond: Double = 0

    /// Rolling history, newest last, in bytes/sec. Sized for the width of the
    /// panel so the graph never has to resample.
    static let historyLen = 160
    private(set) var inHistory  = [Double]()
    private(set) var outHistory = [Double]()

    /// History advances at ~1Hz, not at the poll rate. The graph is redrawn
    /// when a new point lands, and a filled gradient trace is far too expensive
    /// to repaint 2.5 times a second to add a column one pixel wide.
    private var lastHistAt: TimeInterval = 0

    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastAt: TimeInterval = 0

    private func directedBytes() -> (UInt64, UInt64) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let raw = cur.pointee.ifa_data {
                let d = raw.assumingMemoryBound(to: if_data.self)
                rx &+= UInt64(d.pointee.ifi_ibytes)
                tx &+= UInt64(d.pointee.ifi_obytes)
            }
            p = cur.pointee.ifa_next
        }
        return (rx, tx)
    }

    /// Returns true when the level moved enough to be worth redrawing.
    @discardableResult
    func sample() -> Bool {
        if let v = pinned { level = v; return false }
        let now = Date().timeIntervalSince1970
        let (rx, tx) = directedBytes()
        let bytes = rx &+ tx
        defer { lastIn = rx; lastOut = tx; lastAt = now }
        guard lastAt > 0, rx >= lastIn, tx >= lastOut else { return false }

        let dt = now - lastAt
        guard dt > 0.2 else { return false }
        bytesPerSecond    = Double(bytes &- (lastIn &+ lastOut)) / dt
        inBytesPerSecond  = Double(rx - lastIn) / dt
        outBytesPerSecond = Double(tx - lastOut) / dt

        if now - lastHistAt >= 1.0 {
            lastHistAt = now
            inHistory.append(inBytesPerSecond)
            outHistory.append(outBytesPerSecond)
        }
        if inHistory.count  > ThroughputMeter.historyLen { inHistory.removeFirst(inHistory.count - ThroughputMeter.historyLen) }
        if outHistory.count > ThroughputMeter.historyLen { outHistory.removeFirst(outHistory.count - ThroughputMeter.historyLen) }

        // log scale: 1 KB/s registers, 4 MB/s saturates
        let norm = min(1.0, log1p(bytesPerSecond / 1024.0) / log1p(4096.0))
        let before = level
        level += (norm - level) * 0.35          // smooth, so the visual glides
        return abs(level - before) > 0.005
    }
}
