// Telemetry.swift — the ten live health bands and the snapshot reader.
//
// Values are 0.0...1.0, or -1.0 for "unknown", which renders grey and never
// red: an unmeasured band must not look like a failing one.

import Foundation

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
