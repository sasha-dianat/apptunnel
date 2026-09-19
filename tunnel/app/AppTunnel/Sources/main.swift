// AppTunnel — native macOS control panel for the Shadowsocks app tunnel.
// Winamp 2.x replica drawn with AppKit. No web view, no Terminal windows.
//
// Build:  tunnel/app/build.sh      Output: AppTunnel.app
//
// Privileged work runs through the standard macOS authorisation dialog
// (`do shell script … with administrator privileges`) and then detaches into
// the background, so no Terminal ever appears. The password is handled by
// macOS itself and never passes through this process.

import AppKit
import Foundation

// MARK: - Model

struct PhaseDef { let name: String; let label: String }

let PHASES: [PhaseDef] = [
    .init(name: "PREFLIGHT", label: "Checking apps and tools"),
    .init(name: "SOCKS",     label: "Reaching the SOCKS5 endpoint"),
    .init(name: "BRIDGE",    label: "Raising the HTTP-to-SOCKS bridge"),
    .init(name: "PRIV",      label: "Requesting administrator rights"),
    .init(name: "GROUP",     label: "Creating the isolation group"),
    .init(name: "FIREWALL",  label: "Installing group-scoped PF rules"),
    .init(name: "CALIBRATE", label: "Proving the leak test can detect egress"),
    .init(name: "LEAKTEST",  label: "Confirming zero direct egress"),
    .init(name: "PROXYPATH", label: "Verifying the tunnel path"),
    .init(name: "LAUNCH",    label: "Starting the protected apps"),
]

enum PhaseState { case idle, running, ok, failed }

struct RosterApp: Codable { var path: String; var name: String; var enabled: Bool }

final class Model {
    static let shared = Model()

    let stateDir = NSHomeDirectory() + "/.apptunnel"
    var appsFile:    String { stateDir + "/apps.json" }
    var eventsFile:  String { stateDir + "/events.jsonl" }
    var sessionFile: String { stateDir + "/session.json" }
    var stopFile:    String { stateDir + "/stop" }
    var logFile:     String { stateDir + "/launcher.log" }

    var binDir = ""
    var roster: [RosterApp] = []
    var phases  = [PhaseState](repeating: .idle, count: PHASES.count)
    var phaseMsg = [String](repeating: "", count: PHASES.count)
    var currentPhase: Int?
    var lastMessage = ""
    var sessionActive = false
    var connecting = false
    var exitIP = "---.---.---.---"
    var gid = "-----"
    var socksUp = false
    // Discovered from the system proxy settings. VeePN publishes 1180 on some
    // profiles; assuming 1080 made the indicator read "no proxy" forever.
    var socksHost = "127.0.0.1"
    var socksPort: UInt16 = 1080
    /// Bundles currently running inside the tunnel's isolation group.
    var tunnelled: Set<String> = []
    let telemetry = TelemetryStore()
    let net = ThroughputMeter()
    var runFile: String { stateDir + "/run-request" }
    private var scanTick = 0
    var startedAt: Date?
    var demoMode = false
    var protectedHost: String? = nil
    private var cursor = 0

    /// The app bundle tunnel-testkit.sh has marked as protected, if any.
    func readProtection() -> String? {
        guard let d = FileManager.default.contents(atPath: stateDir + "/protected.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let b = o["host_bundle"] as? String, !b.isEmpty else { return nil }
        return b
    }

    func clearProtection() {
        try? FileManager.default.removeItem(atPath: stateDir + "/protected.json")
        protectedHost = nil
    }

    func load() {
        if let d = FileManager.default.contents(atPath: appsFile),
           let r = try? JSONDecoder().decode([RosterApp].self, from: d) { roster = r }
        else {
            roster = ["/Applications/Claude.app", "/Applications/ChatGPT.app"]
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { RosterApp(path: $0,
                                 name: ($0 as NSString).lastPathComponent
                                     .replacingOccurrences(of: ".app", with: ""),
                                 enabled: true) }
            saveRoster()
        }
    }

    func saveRoster() {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = .prettyPrinted
        if let d = try? e.encode(roster) { try? d.write(to: URL(fileURLWithPath: appsFile)) }
    }

    func resetPhases() {
        phases = [PhaseState](repeating: .idle, count: PHASES.count)
        phaseMsg = [String](repeating: "", count: PHASES.count)
        currentPhase = nil
        cursor = 0
    }

    func poll() -> Bool {
        var dirty = false
        let was = sessionActive
        sessionActive = readSession()
        if was != sessionActive {
            dirty = true
            if sessionActive { connecting = false; startedAt = startedAt ?? Date() }
            else if !demoMode {
                startedAt = nil; exitIP = "---.---.---.---"; gid = "-----"
            }
        }
        let up = probeSocks()
        if up != socksUp { socksUp = up; dirty = true }
        let prot = readProtection()
        if prot != protectedHost { protectedHost = prot; dirty = true }
        scanTick += 1
        if scanTick % 5 == 0 {           // ~every 2s, not every poll
            let before = tunnelled
            tunnelled = scanTunnelled()
            if before != tunnelled { dirty = true }
        }
        if !demoMode && consumeEvents() { dirty = true }
        if !demoMode && telemetry.poll() { dirty = true }
        if net.sample() { dirty = true }
        return dirty
    }

    /// A bundle counts as tunnelled when one of its processes carries the
    /// session's isolation gid.
    private func scanTunnelled() -> Set<String> {
        guard let g = UInt32(gid) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "gid=,command="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: d, encoding: .utf8) else { return [] }
        var found: Set<String> = []
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " ") else { continue }
            guard UInt32(t[t.startIndex..<sp]) == g else { continue }
            let cmd = String(t[sp...])
            for a in roster where cmd.contains(a.path + "/Contents/MacOS/") { found.insert(a.path) }
        }
        return found
    }

    private func readSession() -> Bool {
        guard let d = FileManager.default.contents(atPath: sessionFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = o["pid"] as? Int else { return false }
        // The launcher may be root-owned: EPERM still proves it is alive.
        if kill(pid_t(pid), 0) != 0 && errno != EPERM { return false }
        if let ip = o["exit_ip"] as? String { exitIP = ip }
        if let g = o["gid"] as? Int { gid = String(g) }
        return (o["state"] as? String) != "starting"
    }

    /// Read the SOCKS endpoint the VPN advertises to the system.
    private func detectSocks() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--proxy"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: d, encoding: .utf8) else { return }
        func field(_ key: String) -> String? {
            for line in out.split(separator: "\n") where line.contains(key) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        guard field("SOCKSEnable") == "1" else { return }
        if let h = field("SOCKSProxy"), !h.isEmpty { socksHost = h }
        if let s = field("SOCKSPort"), let v = UInt16(s) { socksPort = v }
    }

    private func probeSocks() -> Bool {
        detectSocks()
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = socksPort.bigEndian
        a.sin_addr.s_addr = inet_addr(socksHost)
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private func consumeEvents() -> Bool {
        guard let t = try? String(contentsOfFile: eventsFile, encoding: .utf8) else { return false }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count < cursor { cursor = 0; resetPhases() }
        guard lines.count > cursor else { return false }
        for line in lines[cursor...] {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let name = o["name"] as? String,
                  let st = o["status"] as? String else { continue }
            let msg = (o["msg"] as? String) ?? ""
            if !msg.isEmpty { lastMessage = msg }
            if name == "READY" {
                for i in phases.indices { phases[i] = .ok }
                currentPhase = nil; connecting = false
                continue
            }
            if name == "JOIN" {
                if !msg.isEmpty { lastMessage = msg }
                continue
            }
            if name == "TEARDOWN" || name == "CLEANUP" || name == "STOPPING" {
                if st == "fail" { lastMessage = msg }
                continue
            }
            guard let i = PHASES.firstIndex(where: { $0.name == name }) else { continue }
            switch st {
            case "run":  phases[i] = .running; currentPhase = i
                         connecting = true; startedAt = startedAt ?? Date()
            case "ok":   phases[i] = .ok;      currentPhase = i
            case "fail": phases[i] = .failed;  currentPhase = i; connecting = false
            default: break
            }
            if !msg.isEmpty { phaseMsg[i] = msg }
        }
        cursor = lines.count
        return true
    }

    var completed: Int { phases.filter { $0 == .ok }.count }
    var failed: Bool { phases.contains { $0 == .failed } }
    var enabledApps: [RosterApp] { roster.filter { $0.enabled } }
}

// MARK: - Privileged execution (no Terminal)

enum Runner {
    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func asStr(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs a shell command as root via the macOS authorisation dialog.
    /// Blocking — call off the main thread.
    static func admin(_ shell: String) -> (ok: Bool, out: String) {
        let osa = "do shell script \(asStr(shell)) with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: d, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out)
    }

    /// Runs a shell command as the logged-in user, with no elevation and no
    /// authorisation dialog.
    ///
    /// This is not a convenience: tunnel-veepn-repair.sh reads VeePN's config
    /// from the user's own ~/Library and starts the proxy core on their behalf.
    /// Run through `admin` it would inherit root's HOME, find no config, and
    /// leave a root-owned core behind. Anything that belongs to the user must
    /// run as the user.
    /// Blocking — call off the main thread.
    static func user(_ shell: String) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", shell]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: d, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out)
    }

    /// Same, but the command is detached so the dialog returns immediately.
    ///
    /// No `nohup`: `do shell script` runs without a controlling terminal, so
    /// nohup fails with "can't detach from console" - and it is unnecessary,
    /// because with no TTY there is no SIGHUP to protect against. Backgrounding
    /// the group re-parents it to launchd, which is what we want.
    static func adminDetached(_ shell: String, log: String) -> (ok: Bool, out: String) {
        admin("{ \(shell) ; } > \(q(log)) 2>&1 & echo detached")
    }
}

// MARK: - Reusable chrome

final class TitleBar: NSView {
    var title = "APPTUNNEL"
    var led: NSColor = Skin.metalDeep
    var ledPulse: CGFloat = 0
    var onClose: (() -> Void)?
    var showClose = true
    private var drag = NSPoint.zero

    override func draw(_ dirty: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.27, blue: 0.34, alpha: 1),
                            NSColor(srgbRed: 0.16, green: 0.16, blue: 0.21, alpha: 1)])?
            .draw(in: bounds, angle: -90)
        Skin.metalDeep.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let dot = NSRect(x: 6, y: bounds.midY - 4, width: 8, height: 8)
        led.withAlphaComponent(0.45 + 0.55 * ledPulse).setFill()
        dot.fill()
        bevel(dot, sunken: true)

        let f = Skin.mono(9, true)
        text(title, NSPoint(x: 21, y: bounds.midY - 5), f, NSColor(white: 0.78, alpha: 1))

        let sx = 26 + width(title, f)
        let sw = bounds.width - sx - (showClose ? 24 : 6)
        if sw > 10 {
            NSColor(white: 0.42, alpha: 0.5).setFill()
            var y = bounds.midY - 4
            while y < bounds.midY + 5 { NSRect(x: sx, y: y, width: sw, height: 1).fill(); y += 2 }
        }
        if showClose {
            let c = NSRect(x: bounds.width - 19, y: bounds.midY - 6, width: 13, height: 12)
            Skin.metal.setFill(); c.fill(); bevel(c)
            text("x", NSPoint(x: c.minX + 4, y: c.minY + 1), Skin.mono(8, true), Skin.label)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if showClose && p.x > bounds.width - 21 { onClose?(); return }
        drag = e.locationInWindow
    }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: m.x - drag.x, y: m.y - drag.y))
    }
}

// MARK: - Visualiser (bars + oscilloscope, click to toggle)


// MARK: - Main LCD

final class LCD: NSView {
    var marquee: CGFloat = 0

    override func draw(_ r: NSRect) {
        let m = Model.shared
        Skin.lcd.setFill(); bounds.fill()
        let live = m.sessionActive || m.demoMode

        var clock = "--:--"
        if let s = m.startedAt {
            // Wall time makes a snapshot flap between e.g. 02:14 and 02:15
            // depending on when the render lands. Pin it when deterministic.
            let t = Render.deterministic ? 134 : Int(Date().timeIntervalSince(s))
            clock = String(format: "%02d:%02d", t / 60, t % 60)
        }
        text(clock, NSPoint(x: 8, y: 32), Skin.mono(24, true),
             live ? Skin.green : Skin.greenDim, glow: live ? 0.7 : 0)

        let st = m.failed ? "FAILED" : m.demoMode ? "DEMO"
               : m.sessionActive ? "TUNNELED" : m.connecting ? "CONNECTING" : "IDLE"
        let sc = m.failed ? Skin.red : m.sessionActive ? Skin.green
               : m.connecting ? Skin.amber : Skin.greenDim
        text(st, NSPoint(x: 100, y: 46), Skin.mono(8, true), sc)

        // classic kbps / khz / stereo indicators
        text("SOCKS", NSPoint(x: 100, y: 35), Skin.mono(7),
             m.socksUp ? Skin.greenMid : Skin.greenDim)
        text(m.socksUp ? String(m.socksPort) : "----", NSPoint(x: 141, y: 35),
             Skin.mono(7), m.socksUp ? Skin.greenMid : Skin.greenDim)

        let msg = m.lastMessage.isEmpty ? "apptunnel 2.0  ***  no session" : m.lastMessage
        let f = Skin.mono(10)
        let w = width(msg, f)
        let clip = NSRect(x: 5, y: 17, width: bounds.width - 10, height: 14)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).setClip()
        text(msg, NSPoint(x: clip.minX + marquee, y: clip.minY), f, Skin.green)
        if w + marquee < clip.width {
            text(msg, NSPoint(x: clip.minX + marquee + w + 42, y: clip.minY), f, Skin.green)
        }
        NSGraphicsContext.restoreGraphicsState()

        text("EXIT \(m.exitIP)", NSPoint(x: 8, y: 3), Skin.mono(8), Skin.greenMid)
        let g = "GID \(m.gid)"
        text(g, NSPoint(x: bounds.width - width(g, Skin.mono(8)) - 8, y: 3), Skin.mono(8), Skin.greenMid)
    }

    func advance() {
        let m = Model.shared
        let msg = m.lastMessage.isEmpty ? "apptunnel 2.0  ***  no session" : m.lastMessage
        let w = width(msg, Skin.mono(10))
        marquee -= 0.55
        if marquee < -(w + 42) { marquee = 0 }
        needsDisplay = true
    }
}

// MARK: - Position bar (overall progress)

final class PositionBar: NSView {
    private var shown: CGFloat = 0
    func step() {
        let m = Model.shared
        ease(&shown, CGFloat(m.completed) / CGFloat(PHASES.count), 0.12)
        needsDisplay = true
    }
    override func draw(_ r: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill(); bounds.fill()
        bevel(bounds, sunken: true)
        let inner = bounds.insetBy(dx: 2, dy: 2)
        // groove ticks
        NSColor(white: 0.18, alpha: 1).setFill()
        var x = inner.minX
        while x < inner.maxX { NSRect(x: x, y: inner.midY, width: 1, height: 1).fill(); x += 4 }
        let m = Model.shared
        let c: NSColor = m.failed ? Skin.red : m.sessionActive ? Skin.green : Skin.amber
        let w = inner.width * shown
        if w > 1 {
            NSGradient(colors: [c.shadow(withLevel: 0.45) ?? c, c])?
                .draw(in: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height), angle: 0)
        }
        // thumb
        let tx = inner.minX + max(0, w - 4)
        let thumb = NSRect(x: tx, y: inner.minY - 1, width: 9, height: inner.height + 2)
        NSGradient(colors: [NSColor(white: 0.60, alpha: 1), NSColor(white: 0.28, alpha: 1)])?
            .draw(in: thumb, angle: -90)
        bevel(thumb)
    }
}

// MARK: - Phase equaliser

final class PhaseBars: NSView {
    private var shown = [CGFloat](repeating: 0.04, count: PHASES.count)
    private var pulse: CGFloat = 0
    private var flash = [CGFloat](repeating: 0, count: PHASES.count)
    private var wasOK = [Bool](repeating: false, count: PHASES.count)

    func step() {
        let m = Model.shared
        pulse += 0.09
        for i in 0..<PHASES.count {
            let st = m.phases[i]
            let target: CGFloat = st == .ok ? 1 : st == .running ? 0.55 : st == .failed ? 1 : 0.04
            ease(&shown[i], target, 0.16)
            let isOK = st == .ok
            if isOK && !wasOK[i] { flash[i] = 1 }     // celebrate the moment it lands
            wasOK[i] = isOK
            if flash[i] > 0 { flash[i] = max(0, flash[i] - 0.05) }
        }
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        let m = Model.shared
        Skin.lcd.setFill(); bounds.fill()
        bevel(bounds, sunken: true)

        NSColor(srgbRed: 0.05, green: 0.16, blue: 0.06, alpha: 1).setFill()
        var gx: CGFloat = 6
        while gx < bounds.width - 6 { NSRect(x: gx, y: bounds.midY, width: 2, height: 1).fill(); gx += 5 }

        let slot = (bounds.width - 14) / CGFloat(PHASES.count)
        let trackH = bounds.height - 30
        for i in 0..<PHASES.count {
            let cx = 7 + slot * (CGFloat(i) + 0.5)
            let track = NSRect(x: cx - 5, y: 20, width: 10, height: trackH)
            NSColor(white: 0.05, alpha: 1).setFill(); track.fill()
            bevel(track, sunken: true)

            let st = m.phases[i]
            var c: NSColor = st == .ok ? Skin.green : st == .running ? Skin.amber
                           : st == .failed ? Skin.red : Skin.greenDim
            if st == .running {
                c = c.withAlphaComponent(0.55 + 0.45 * CGFloat(abs(sin(pulse))))
            }
            let fh = max(2, (trackH - 2) * shown[i])
            let fill = NSRect(x: track.minX + 1, y: track.minY + 1, width: 8, height: fh)
            NSGradient(colors: [c, c.shadow(withLevel: 0.55) ?? c])?.draw(in: fill, angle: -90)

            if flash[i] > 0 {
                Skin.green.withAlphaComponent(flash[i] * 0.55).setFill()
                fill.insetBy(dx: -3, dy: -3).fill()
            }

            let knob = NSRect(x: cx - 7, y: track.minY + fh - 2, width: 14, height: 5)
            NSGradient(colors: [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.26, alpha: 1)])?
                .draw(in: knob, angle: -90)
            bevel(knob)

            let lbl = "\(i + 1)"
            text(lbl, NSPoint(x: cx - width(lbl, Skin.mono(8)) / 2, y: 6), Skin.mono(8), c)
        }
    }
}

// MARK: - Button

final class Btn: NSView {
    let title: String
    var tint: NSColor
    var action: () -> Void
    private var down = false
    private var hover = false

    /// One-line description shown on hover: as a system tooltip, and in the
    /// caption strip so it is readable without waiting for the tooltip delay.
    let tip: String
    var onHover: ((String?) -> Void)?

    init(_ t: String, _ w: CGFloat, tint: NSColor = Skin.label,
         tip: String = "", _ a: @escaping () -> Void) {
        title = t; self.tint = tint; action = a; self.tip = tip
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 23))
        if !tip.isEmpty { toolTip = tip }
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self)
        addTrackingArea(ta)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) {
        hover = true; needsDisplay = true
        if !tip.isEmpty { onHover?(tip) }
    }
    override func mouseExited(with e: NSEvent) {
        hover = false; needsDisplay = true
        onHover?(nil)
    }

    override func draw(_ r: NSRect) {
        let top = down ? NSColor(white: 0.13, alpha: 1)
                       : NSColor(srgbRed: hover ? 0.36 : 0.31, green: hover ? 0.36 : 0.31,
                                 blue: hover ? 0.45 : 0.39, alpha: 1)
        let bot = down ? Skin.metal : NSColor(srgbRed: 0.19, green: 0.19, blue: 0.25, alpha: 1)
        NSGradient(colors: [top, bot])?.draw(in: bounds, angle: -90)
        bevel(bounds, sunken: down)
        let f = Skin.mono(title.count > 3 ? 8 : 11, true)
        let s = (title as NSString).size(withAttributes: [.font: f])
        text(title, NSPoint(x: (bounds.width - s.width) / 2 + (down ? 1 : 0),
                            y: (bounds.height - s.height) / 2 - (down ? 1 : 0)),
             f, tint, glow: hover ? 0.35 : 0)
    }

    override func mouseDown(with e: NSEvent) { down = true; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        down = false; needsDisplay = true
        if bounds.contains(convert(e.locationInWindow, from: nil)) { action() }
    }
}

// MARK: - Roster

final class Roster: NSView {
    var onChange: (() -> Void)?
    var onRun: ((RosterApp) -> Void)?
    private let runW: CGFloat = 40
    private(set) var selected: Int?
    private let rowH: CGFloat = 21

    override func draw(_ r: NSRect) {
        NSColor(srgbRed: 0.015, green: 0.02, blue: 0.015, alpha: 1).setFill(); bounds.fill()
        bevel(bounds, sunken: true)
        let m = Model.shared
        if m.roster.isEmpty {
            text("roster is empty  —  press  + ADD APP",
                 NSPoint(x: 14, y: bounds.height / 2 - 6), Skin.mono(10), Skin.greenDim)
            return
        }
        for (i, a) in m.roster.enumerated() {
            let y = bounds.height - rowH * CGFloat(i + 1) - 2
            guard y > -rowH else { break }
            if selected == i {
                NSColor(srgbRed: 0.06, green: 0.14, blue: 0.28, alpha: 1).setFill()
                NSRect(x: 2, y: y, width: bounds.width - 4, height: rowH).fill()
            }
            let c = a.enabled ? Skin.green : Skin.greenDim
            let box = NSRect(x: 9, y: y + 5, width: 11, height: 11)
            NSColor(white: 0.02, alpha: 1).setFill(); box.fill()
            c.setStroke(); NSBezierPath(rect: box).stroke()
            if a.enabled {
                let p = NSBezierPath(); p.lineWidth = 1.6
                p.move(to: NSPoint(x: box.minX + 2, y: box.midY))
                p.line(to: NSPoint(x: box.midX - 0.5, y: box.minY + 2.5))
                p.line(to: NSPoint(x: box.maxX - 1.5, y: box.maxY - 2.5))
                Skin.green.setStroke(); p.stroke()
            }
            text("\(i + 1).", NSPoint(x: 26, y: y + 5), Skin.mono(9), Skin.greenDim)
            text(a.name, NSPoint(x: 46, y: y + 5), Skin.mono(11), c)
            // Per-app control on the right: already inside the tunnel, or a
            // RUN chip that adds just this app without disturbing the others.
            let chip = NSRect(x: bounds.width - runW - 8, y: y + 3, width: runW, height: 15)
            let inside = Model.shared.tunnelled.contains(a.path)
            if inside {
                text("IN", NSPoint(x: chip.minX + 12, y: chip.minY + 2), Skin.mono(9, true), Skin.green)
            } else if a.enabled {
                NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.30, blue: 0.38, alpha: 1),
                                    NSColor(srgbRed: 0.18, green: 0.18, blue: 0.24, alpha: 1)])?
                    .draw(in: chip, angle: -90)
                bevel(chip)
                text("RUN", NSPoint(x: chip.minX + 9, y: chip.minY + 2), Skin.mono(9, true), Skin.amber)
            }
            let pf = Skin.mono(8)
            text(a.path, NSPoint(x: bounds.width - runW - width(a.path, pf) - 18, y: y + 6),
                 pf, NSColor(white: 0.30, alpha: 1))
            NSColor(white: 0.07, alpha: 1).setFill()
            NSRect(x: 2, y: y, width: bounds.width - 4, height: 1).fill()
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = Int((bounds.height - p.y - 2) / rowH)
        guard i >= 0, i < Model.shared.roster.count else { return }
        selected = i
        let a = Model.shared.roster[i]
        // The RUN chip is a separate control: clicking it must not toggle the tick.
        if p.x >= bounds.width - runW - 8, a.enabled, !Model.shared.tunnelled.contains(a.path) {
            needsDisplay = true
            onRun?(a)
            return
        }
        Model.shared.roster[i].enabled.toggle()
        Model.shared.saveRoster()
        needsDisplay = true
        onChange?()
    }
    func clearSelection() { selected = nil; needsDisplay = true }
}

// MARK: - Output window

final class LogWindow: NSWindow {
    private var tv: NSTextView!

    init(title: String, body: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                   styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        backgroundColor = Skin.metal
        isMovableByWindowBackground = false
        let root = NSView(frame: contentRect(forFrameRect: frame))
        root.autoresizingMask = [.width, .height]
        contentView = root

        let tb = TitleBar(frame: NSRect(x: 0, y: root.bounds.height - 20,
                                        width: root.bounds.width, height: 20))
        tb.title = title
        tb.led = Skin.greenMid
        tb.ledPulse = 1
        tb.autoresizingMask = [.width, .minYMargin]
        tb.onClose = { [weak self] in self?.close() }
        root.addSubview(tb)

        let scroll = NSScrollView(frame: NSRect(x: 6, y: 6,
                                                width: root.bounds.width - 12,
                                                height: root.bounds.height - 30))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Skin.lcd

        // An NSTextView built with NSTextView() has a zero-sized text container,
        // so it lays out nothing and the window renders as a blank black panel.
        // It must be given a real frame and an explicitly sized container.
        let size = scroll.contentSize
        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: size.width,
                                                   height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = Skin.lcd
        text.textColor = Skin.green
        text.font = Skin.mono(11)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.string = body.isEmpty ? "(the command produced no output)" : body
        scroll.documentView = text
        tv = text
        root.addSubview(scroll)
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Command-W closes the panel rather than beeping (no .closable in the mask)
    /// and must NOT quit the app - only the main window means that.
    override func performClose(_ sender: Any?) { close() }
    func append(_ s: String) { tv.string += s; tv.scrollToEndOfDocument(nil) }
}

// MARK: - Backdrop

final class Backdrop: NSView {
    override func draw(_ r: NSRect) {
        NSGradient(colors: [Skin.metal, Skin.metalLo])?.draw(in: bounds, angle: -90)
        bevel(bounds)
    }
}

// MARK: - Main window

final class Main: NSWindow {
    let vis = Visualiser(frame: .zero)
    let lcd = LCD(frame: .zero)
    let pos = PositionBar(frame: .zero)
    let bars = PhaseBars(frame: .zero)
    let roster = Roster(frame: .zero)
    let tb = TitleBar(frame: .zero)
    let caption = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    private var logWindows: [LogWindow] = []
    private var busy = false

    init() {
        // 662, not 556: the button row is laid out left to right and already
        // ended at x=504 in a 556-wide window. Everything else on the panel is
        // sized from the window width (W - 16, W - 190), so widening stretches
        // rather than breaks it.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 662, height: 500),
                   styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        backgroundColor = Skin.metal
        hasShadow = true
        contentView = Backdrop(frame: contentRect(forFrameRect: frame))
        layout()
        center()

        // Snapshot modes drive the views explicitly with a fixed step count.
        // Letting the timers also run made an indeterminate number of extra
        // frames land before capture, so no two renders matched.
        if !Render.deterministic {
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.vis.step(); self?.lcd.advance(); self?.bars.step(); self?.pos.step()
                self?.pulseLED()
            }
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                if Model.shared.poll() { self?.refresh() }
    
        }
    }
    }

    private var ledPhase: CGFloat = 0
    private func pulseLED() {
        let m = Model.shared
        ledPhase += 0.12
        tb.ledPulse = (m.connecting || m.demoMode) ? CGFloat(abs(sin(ledPhase))) : 1
        tb.needsDisplay = true
    }

    private func layout() {
        guard let root = contentView else { return }
        let W = root.bounds.width, H = root.bounds.height
        var y = H

        // ---- player window
        y -= 20
        tb.frame = NSRect(x: 0, y: y, width: W, height: 20)
        tb.onClose = { NSApp.terminate(nil) }
        root.addSubview(tb)

        y -= 66
        vis.frame = NSRect(x: 8, y: y, width: 170, height: 62)
        vis.onHover = { [weak self] t in self?.showHint(t) }
        root.addSubview(vis)
        lcd.frame = NSRect(x: 182, y: y, width: W - 190, height: 62)
        root.addSubview(lcd)

        y -= 16
        pos.frame = NSRect(x: 8, y: y, width: W - 16, height: 12)
        root.addSubview(pos)

        y -= 29
        var x: CGFloat = 8
        func add(_ b: Btn, gap: CGFloat = 2) {
            b.onHover = { [weak self] t in self?.showHint(t) }
            b.setFrameOrigin(NSPoint(x: x, y: y)); root.addSubview(b); x += b.frame.width + gap
        }
        add(Btn("|<<", 34,
                tip: "CHECK — read-only health report: VPN endpoint, leftover firewall rules, orphaned groups, stale proxy settings. Changes nothing.")
                { self.runDoctor(fix: false) })
        add(Btn(">", 34, tint: Skin.green,
                tip: "CONNECT — quits the ticked apps and relaunches them inside one tunnel. Asks for your admin password once; no Terminal opens.")
                { self.connect() })
        add(Btn("||", 34,
                tip: "DEMO — plays the ten-phase animation so you can see what a connection looks like. Touches nothing at all.")
                { self.demo() })
        add(Btn("[]", 34, tint: Skin.red,
                tip: "DISCONNECT — ends the tunnel, removes the firewall rules and temporary group, and restores every setting it changed.")
                { self.disconnect() })
        add(Btn(">>|", 34,
                tip: "REPAIR — removes orphaned groups, dead bridges, stale firewall anchors and dead proxy entries. Never touches DHCP, DNS or Wi-Fi.")
                { self.runDoctor(fix: true) }, gap: 10)
        add(Btn("VPN REPAIR", 96, tint: Skin.green,
                tip: "Brings the VeePN tunnel up. Press this first if CONNECT stops at phase 2: VeePN says \"connected\" while its core is not actually running, so there is no SOCKS5 endpoint to tunnel through. Runs as you, asks for no password, and leaves running apps alone.")
                { self.repairVPN() }, gap: 10)
        add(Btn("DNS RESCUE", 92, tint: Skin.amber,
                tip: "Use if the whole Mac loses the Internet. Finds firewall rules that block DNS machine-wide and removes only those. Do NOT reset your network settings instead.")
                { self.runDNSGuard() }, gap: 10)
        add(Btn("+ ADD APP", 78,
                tip: "Add an application to the roster. Ticked apps are launched into the tunnel for you when you press play.")
                { self.addApp() })
        add(Btn("- REMOVE", 76,
                tip: "Remove the selected row from the roster. Select a row first.")
                { self.removeApp() })
        add(Btn("TEST", 46, tint: Skin.amber,
                tip: "TEST MODE — protects the app this panel runs inside so connecting cannot kill a session running in it. That app is then left OUT of the tunnel.")
                { self.toggleProtection() })

        // ---- phase window
        y -= 22
        let l1 = NSTextField(labelWithString: "CONNECTION PHASES")
        l1.font = Skin.mono(9, true); l1.textColor = Skin.label
        l1.frame = NSRect(x: 10, y: y, width: 220, height: 14)
        root.addSubview(l1)

        y -= 116
        bars.frame = NSRect(x: 8, y: y, width: W - 16, height: 112)
        root.addSubview(bars)

        y -= 18
        caption.font = Skin.mono(9); caption.textColor = Skin.greenDim
        caption.frame = NSRect(x: 10, y: y, width: W - 20, height: 14)
        root.addSubview(caption)

        // ---- roster window
        y -= 22
        let l2 = NSTextField(labelWithString: "TUNNEL ROSTER   (click a row to include / exclude \u{2022} RUN adds it to a live tunnel)")
        l2.font = Skin.mono(9, true); l2.textColor = Skin.label
        l2.frame = NSRect(x: 10, y: y, width: W - 20, height: 14)
        root.addSubview(l2)

        let rosterTop = y - 6
        roster.frame = NSRect(x: 8, y: 34, width: W - 16, height: rosterTop - 34)
        roster.onChange = { [weak self] in self?.refresh() }
        roster.onRun = { [weak self] a in self?.runOne(a) }
        root.addSubview(roster)

        hint.font = Skin.mono(8); hint.textColor = NSColor(white: 0.42, alpha: 1)
        hint.frame = NSRect(x: 10, y: 5, width: W - 20, height: 24)
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.cell?.wraps = true
        hint.cell?.isScrollable = false
        hint.stringValue = "\u{25B6} starts the tunnel with every ticked app. RUN adds one app to a tunnel that is already running, leaving the others untouched. Apps opened from Finder or the Dock are NOT tunnelled."
        root.addSubview(hint)
    }

    /// Hover text temporarily replaces the caption; nil restores the real state.
    private var hintOverride: String?
    func showHint(_ t: String?) {
        hintOverride = t
        if let t = t {
            caption.stringValue = t
            caption.textColor = Skin.label
            caption.toolTip = t
        } else {
            refresh()
        }
    }

    func refresh() {
        if hintOverride != nil { return }   // do not fight the hover description
        let m = Model.shared
        tb.led = m.failed ? Skin.red : m.sessionActive ? Skin.green
               : m.connecting ? Skin.amber : m.socksUp ? Skin.greenDim : Skin.metalDeep
        tb.title = m.protectedHost != nil ? "APPTUNNEL  —  TEST MODE"
                 : m.sessionActive ? "APPTUNNEL  —  TUNNELED" : "APPTUNNEL"
        if let i = m.currentPhase {
            let st = m.phases[i]
            let tag = st == .ok ? "OK" : st == .failed ? "FAIL" : "..."
            caption.stringValue = "\(i + 1). \(PHASES[i].name) [\(tag)]  \(m.phaseMsg[i])"
            caption.textColor = st == .failed ? Skin.red : st == .ok ? Skin.green : Skin.amber
        } else if let host = m.protectedHost {
            caption.stringValue = "TEST MODE — \(( host as NSString ).lastPathComponent) is protected and will NOT be tunnelled"
            caption.textColor = Skin.amber
        } else if !m.socksUp {
            caption.stringValue = "no SOCKS5 proxy on \(m.socksHost):\(m.socksPort) — connect VeePN (Shadowsocks) first"
            caption.textColor = Skin.red
        } else {
            caption.stringValue = "ready — all ten bands turn green when the tunnel is verified"
            caption.textColor = Skin.greenDim
        }
        [tb, lcd, bars, roster, pos].forEach { $0.needsDisplay = true }
    }

    // MARK: actions

    private func script(_ n: String) -> String { Model.shared.binDir + "/" + n }

    private func withBusy(_ label: String, _ work: @escaping () -> (Bool, String),
                          done: @escaping (Bool, String) -> Void) {
        guard !busy else { return }
        busy = true
        Model.shared.lastMessage = label
        refresh()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async { self.busy = false; done(r.0, r.1) }
        }
    }

    func connect() {
        let m = Model.shared
        if m.sessionActive { warn("A tunnel is already running.", "Press the stop button first."); return }
        var apps = m.enabledApps
        guard !apps.isEmpty else { warn("Nothing to launch.", "Tick at least one app in the roster."); return }

        // Test protection skips the host app. If that leaves nothing, the
        // launcher would abort at PREFLIGHT with a message the user never sees.
        if let host = m.protectedHost {
            let remaining = apps.filter { $0.path != host }
            if remaining.isEmpty {
                let a = NSAlert()
                a.messageText = "Test protection is on."
                a.informativeText = """
                \(( host as NSString ).lastPathComponent) is marked as the protected host, and it is \
                the only app ticked — so there would be nothing left to tunnel.

                Turning protection off lets it be tunnelled, but the app will be \
                restarted, which ends anything running inside it.
                """
                a.addButton(withTitle: "Turn off and launch")
                a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                m.clearProtection()
            } else if remaining.count != apps.count {
                let a = NSAlert()
                a.messageText = "\(( host as NSString ).lastPathComponent) will be left out."
                a.informativeText = "Test protection is on, so it stays outside the tunnel. "
                                  + "The others will be tunnelled normally."
                a.addButton(withTitle: "Continue"); a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                apps = remaining
            }
        }
        if !m.socksUp {
            let a = NSAlert()
            a.messageText = "No SOCKS5 proxy on \(m.socksHost):\(m.socksPort)"
            a.informativeText = "Connect VeePN using Shadowsocks first. Start anyway?"
            a.addButton(withTitle: "Start anyway"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        try? "".write(toFile: m.eventsFile, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: m.stopFile)
        m.resetPhases(); m.demoMode = false; m.connecting = true
        m.startedAt = Date(); m.lastMessage = "authorising…"
        refresh()

        var cmd = Runner.q(script("tunnel-connect.sh"))
        cmd += " --login-user " + Runner.q(NSUserName())
        for a in apps { cmd += " --app " + Runner.q(a.path) }
        cmd += " --yes"
        let log = m.logFile
        withBusy("authorising…", { Runner.adminDetached(cmd, log: log) }) { ok, out in
            if !ok {
                m.connecting = false
                m.lastMessage = out.contains("-128") ? "cancelled" : "could not start: \(out)"
                self.refresh()
                if !out.contains("-128") { self.showLog("LAUNCH FAILED", out) }
            } else {
                m.lastMessage = "launcher running in the background…"
                self.refresh()
            }
        }
    }

    func disconnect() {
        let m = Model.shared
        guard m.sessionActive || m.connecting else {
            warn("No running session.", "Nothing to disconnect."); return
        }
        // The launcher is root-owned, so we ask it to stop via a flag file it polls.
        //
        // The file carries provenance rather than being empty. "The tunnel
        // dropped" has many possible causes and they look identical afterwards;
        // recording who asked, from which process, at what moment is the one
        // fact that cannot be reconstructed later. tunnel-forensics.sh reads it.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let info = "{\"who\":\"AppTunnel stop button\",\"pid\":"
                 + "\(ProcessInfo.processInfo.processIdentifier),"
                 + "\"user\":\"\(NSUserName())\",\"at\":\"\(stamp)\"}"
        FileManager.default.createFile(atPath: m.stopFile,
                                       contents: info.data(using: .utf8))
        m.lastMessage = "stop requested — restoring system state…"
        refresh()
    }

    func runDoctor(fix: Bool) {
        if fix {
            let a = NSAlert()
            a.messageText = "Repair leftovers?"
            a.informativeText = """
            Removes orphaned isolation groups, dead bridge processes, stale PF \
            anchors and dead proxy entries.

            It does not touch DHCP, DNS servers, Wi-Fi or any network service.
            """
            a.addButton(withTitle: "Repair"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        // Run as root via the authorisation dialog, so the login user must be
        // named explicitly: SUDO_USER is absent (or misleading) there.
        let cmd = Runner.q(script("tunnel-doctor.sh"))
                + " --login-user " + Runner.q(NSUserName())
                + (fix ? " --fix" : "") + " 2>&1"
        withBusy(fix ? "repairing…" : "running diagnostics…", { Runner.admin(cmd) }) { ok, out in
            Model.shared.lastMessage = ok ? "diagnostics complete" : "diagnostics failed"
            self.refresh()
            self.showLog(fix ? "TUNNEL DOCTOR — REPAIR" : "TUNNEL DOCTOR — READ ONLY", self.strip(out))
        }
    }

    /// Bring VeePN's Shadowsocks tunnel up, so CONNECT has a SOCKS5 endpoint
    /// to find. VeePN.app reports "connected" while its core is not running,
    /// which leaves 127.0.0.1 with no listener and stalls the launcher at
    /// phase 2. Safe to press at any time: it starts a proxy core and repoints
    /// the system proxy, and never signals the launcher or the tunnelled apps.
    func repairVPN() {
        let cmd = Runner.q(script("tunnel-veepn-repair.sh")) + " 2>&1"
        withBusy("bringing the VeePN tunnel up…", { Runner.user(cmd) }) { ok, out in
            Model.shared.lastMessage = ok ? "VPN tunnel up" : "VPN repair failed"
            self.refresh()
            self.showLog("VPN REPAIR", self.strip(out))
        }
    }

    func runDNSGuard() {
        let a = NSAlert()
        a.messageText = "Disarm machine-wide DNS blocks?"
        a.informativeText = """
        The old launchers wrote firewall rules that block DNS for the whole Mac, \
        not just the tunnelled apps. This finds and removes only those rules; \
        group-scoped rules are left alone.

        Use this if your Internet stops working. Do not reset your network \
        settings — the cause is a firewall anchor, not DHCP.
        """
        a.addButton(withTitle: "Scan and disarm"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let cmd = Runner.q(script("tunnel-dnsguard.sh")) + " --fix 2>&1"
        withBusy("scanning firewall anchors…", { Runner.admin(cmd) }) { ok, out in
            Model.shared.lastMessage = ok ? "DNS rescue complete" : "DNS rescue failed"
            self.refresh()
            self.showLog("DNS RESCUE", self.strip(out))
        }
    }

    private func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func showLog(_ title: String, _ body: String) {
        let w = LogWindow(title: title, body: body.isEmpty ? "(no output)" : body)
        w.makeKeyAndOrderFront(nil)
        logWindows.append(w)
    }

    func addApp() {
        let p = NSOpenPanel()
        p.title = "Add an app to the tunnel"
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.allowedFileTypes = ["app"]
        p.treatsFilePackagesAsDirectories = false
        guard p.runModal() == .OK else { return }
        let m = Model.shared
        var added = 0
        for u in p.urls {
            guard FileManager.default.fileExists(atPath: u.path + "/Contents/MacOS") else { continue }
            if m.roster.contains(where: { $0.path == u.path }) { continue }
            m.roster.append(RosterApp(path: u.path,
                                      name: u.deletingPathExtension().lastPathComponent,
                                      enabled: true))
            added += 1
        }
        m.saveRoster()
        if added > 0 && m.sessionActive {
            warn("Added to the roster.",
                 "Press its RUN chip to add it to the tunnel that is already running — "
               + "the other apps keep going and are not touched.")
        }
        refresh()
    }

    func toggleProtection() {
        let m = Model.shared
        if m.protectedHost != nil {
            m.clearProtection()
            m.lastMessage = "test protection off — every roster app will be tunnelled"
            refresh()
            return
        }
        let a = NSAlert()
        a.messageText = "Turn on test protection?"
        a.informativeText = """
        Marks the app this control panel was launched from as protected. Connect \
        and repair will then leave it and its processes alone, so testing cannot \
        kill a session running inside it.

        That app will not be tunnelled while this is on.
        """
        a.addButton(withTitle: "Turn on"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let cmd = Runner.q(script("tunnel-testkit.sh")) + " protect --pid " + String(ProcessInfo.processInfo.processIdentifier) + " 2>&1"
        withBusy("arming test protection…", {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (false, "\(error)") }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus == 0, String(data: d, encoding: .utf8) ?? "")
        }) { ok, out in
            _ = m.poll(); self.refresh()
            self.showLog("TEST PROTECTION", self.strip(out))
        }
    }

    /// Add one app to the tunnel that is already running, leaving every other
    /// app untouched. The live launcher performs the join as root, so this
    /// needs no password.
    func runOne(_ a: RosterApp) {
        let m = Model.shared
        guard m.sessionActive else {
            let alert = NSAlert()
            alert.messageText = "No tunnel is running yet."
            alert.informativeText = """
            RUN adds a single app to a tunnel that is already up, without \
            disturbing the others.

            Press \u{25B6} once to start the tunnel, then use RUN to add apps \
            one at a time.
            """
            alert.addButton(withTitle: "OK"); alert.runModal()
            return
        }
        if m.tunnelled.contains(a.path) {
            m.lastMessage = "\(a.name) is already inside the tunnel"; refresh(); return
        }
        let alert = NSAlert()
        alert.messageText = "Add \(a.name) to the running tunnel?"
        alert.informativeText = """
        \(a.name) will be quit and reopened inside the tunnel. Every other app \
        keeps running and is not touched.

        An app cannot be moved in while it is open outside the tunnel, so this \
        one restart is unavoidable.
        """
        alert.addButton(withTitle: "Run \(a.name)"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try a.path.write(toFile: m.runFile, atomically: true, encoding: .utf8)
            m.lastMessage = "adding \(a.name) to the tunnel…"
        } catch {
            m.lastMessage = "could not send the request: \(error.localizedDescription)"
        }
        refresh()
    }

    func removeApp() {
        guard let i = roster.selected, i < Model.shared.roster.count else {
            warn("Select a row first.", "Click an app in the roster, then press Remove."); return
        }
        Model.shared.roster.remove(at: i)
        Model.shared.saveRoster()
        roster.clearSelection()
        refresh()
    }

    func demo() {
        let m = Model.shared
        guard !m.demoMode, !m.connecting else { return }
        m.demoMode = true; m.resetPhases(); m.startedAt = Date()
        m.exitIP = "91.207.57.102"; m.gid = "57463"
        let sample = [
            "2 app(s): Claude ChatGPT",
            "tunnel exit IP 91.207.57.102",
            "bridge http://127.0.0.1:53220 verified",
            "already elevated (no Terminal needed)",
            "group apptun4821 (gid=57321)",
            "60 rules in com.apple/apptunnel-4821",
            "control probe reached 5/5 targets — test is meaningful",
            "0/5 targets reachable directly — guard is enforcing",
            "tunnel path verified at 91.207.57.102",
            "2 app(s) running inside the tunnel",
        ]
        var i = 0
        func next() {
            guard i < PHASES.count else {
                m.lastMessage = "DEMO — ten phases green, apps would now be protected"
                m.currentPhase = nil; self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    m.demoMode = false; m.startedAt = nil
                    m.exitIP = "---.---.---.---"; m.gid = "-----"
                    m.resetPhases(); self.refresh()
                }
                return
            }
            m.phases[i] = .running; m.currentPhase = i
            m.lastMessage = "PHASE \(i + 1)/10 — " + PHASES[i].label
            self.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.66) {
                m.phases[i] = .ok; m.phaseMsg[i] = sample[i]; m.lastMessage = sample[i]
                self.refresh(); i += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: next)
            }
        }
        next()
    }

    private func warn(_ m: String, _ i: String) {
        let a = NSAlert(); a.messageText = m; a.informativeText = i
        a.addButton(withTitle: "OK"); a.runModal()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Command-W. A borderless window has no close button, so the stock
    /// performClose: would just beep. This is the single window of the app, and
    /// the painted X quits, so Command-W means the same thing.
    override func performClose(_ sender: Any?) { NSApp.terminate(nil) }
}

// MARK: - Delegate

final class Delegate: NSObject, NSApplicationDelegate {
    var win: Main?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Before anything that can show an alert: without a main menu there are
        // no key equivalents at all, so Command-Q is dead even on the error path.
        AppMenu.install()

        // Lets the suite prove the shortcuts are really bound, rather than
        // grepping the source and hoping. Prints one "title<tab>modifiers+key"
        // line per item and exits.
        if CommandLine.arguments.contains("--dump-menu") {
            print(AppMenu.describe())
            exit(0)
        }

        let m = Model.shared
        var dir = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        for _ in 0..<6 {
            for c in [dir + "/tunnel/bin", dir + "/bin"] where fm.fileExists(atPath: c + "/tunnel-lock.sh") {
                m.binDir = c; break
            }
            if !m.binDir.isEmpty { break }
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty || dir == "/" { break }
        }
        if m.binDir.isEmpty {
            let a = NSAlert()
            a.messageText = "Tunnel scripts not found."
            a.informativeText = "Keep AppTunnel.app inside the \"Claude-Chatgpt Tunnel\" folder."
            a.addButton(withTitle: "Quit"); a.runModal()
            NSApp.terminate(nil); return
        }
        m.load()
        _ = m.poll()
        let w = Main()
        w.makeKeyAndOrderFront(nil)
        w.refresh()
        win = w
        comeToFront(w)

        let args = CommandLine.arguments
        // Any snapshot mode renders deterministically so the suite can compare.
        if args.contains(where: { $0.hasPrefix("--snapshot") }) {
            Render.deterministic = true
            Render.reseed()
        }
        // Deterministic telemetry render for the suite: synthetic values, no
        // live session required.
        if let i = args.firstIndex(of: "--snapshot-eq"), i + 1 < args.count {
            let out = args[i + 1]
            // Optional 3rd arg: synthetic FLOW, so the suite can capture the
            // display both idle and under load.
            let synthFlow = (i + 3 < args.count ? Double(args[i + 3]) : nil) ?? 0.34
            let synthetic = """
            {"t": \(Date().timeIntervalSince1970),
             "link":1.0,"dns":0.92,"socks":1.0,"bridge":0.88,"exit":1.0,
             "rtt":0.61,"flow":\(synthFlow),"seal":1.0,"wall":1.0,"grip":1.0,
             "score":0.93,"exit_ip":"91.207.57.102",
             "detail":{"link":"gateway 192.168.85.229","dns":"48ms","socks":"127.0.0.1:1080 6ms",
                       "bridge":"12ms","exit":"91.207.57.102","rtt":"180ms","flow":"3 conn",
                       "seal":"0/3 reachable","wall":"60 rules","grip":"14 inside"}}
            """
            let dir = NSHomeDirectory() + "/.apptunnel"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? synthetic.write(toFile: dir + "/telemetry.json", atomically: true, encoding: .utf8)
            m.sessionActive = true
            _ = m.telemetry.poll()
            // Optional trailing arg picks the analyser mode to capture.
            if i + 2 < args.count, let md = Int(args[i + 2]) { w.vis.mode = md }
            if i + 3 < args.count, let fl = Double(args[i + 3]) { m.net.pinned = fl }
            for _ in 0..<120 { w.vis.step() }
            w.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: out))
                        FileHandle.standardError.write("eq snapshot: \(out)\n".data(using: .utf8)!)
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot-log"), i + 1 < args.count {
            let out = args[i + 1]
            let sample = """
            tunnel-doctor  MODE: FIX

            == Active session ==
               ok   no launcher session running

            == Temporary isolation groups ==
               XX   cldesk45058 (gid 57058) orphaned - no process uses it
               ->   removing group cldesk45058
               ok   deleted cldesk45058

            == Packet filter ==
               ok   pf is enabled
               ok   main ruleset references com.apple/* (anchors are evaluated)
               ok   no launcher PF anchors present

            == Summary ==
               1 issue(s) processed. Re-run to confirm.
            """
            let lw = LogWindow(title: "TUNNEL DOCTOR - REPAIR", body: sample)
            lw.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let v = lw.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: out))
                        FileHandle.standardError.write("log snapshot: \(out)\n".data(using: .utf8)!)
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(w, to: args[i + 1])
        }
    }

    /// Raise the window on Sonoma, where the old incantation stopped working.
    ///
    /// macOS 14 deprecated `activate(ignoringOtherApps:)` and, more to the
    /// point, made the "ignoring" half a no-op: an app that was not started by
    /// a user gesture is no longer allowed to steal focus. This app IS started
    /// that way - the launcher spawns it from a detached shell - so on Sonoma
    /// the window was created, ordered front within our own (inactive) app, and
    /// left sitting behind everything else. From the user's side the app simply
    /// did not appear.
    ///
    /// `orderFrontRegardless()` is the part that still works unconditionally:
    /// it puts the window above other applications' windows without requiring
    /// activation. The activate call is kept for the keyboard focus, using the
    /// modern spelling where it exists, and is repeated once on the next runloop
    /// pass because the launcher's own activation can land a beat after ours.
    private func comeToFront(_ w: NSWindow) {
        func raise() {
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            w.orderFrontRegardless()
            w.makeKey()
        }
        raise()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { raise() }
    }

    private func snapshot(_ w: Main, to out: String) {
        let m = Model.shared
        m.demoMode = true; m.socksUp = true
        m.exitIP = "91.207.57.102"; m.gid = "57463"
        m.startedAt = Date().addingTimeInterval(-134)
        let msgs = ["2 app(s): Claude ChatGPT",
                    "tunnel exit IP 91.207.57.102",
                    "bridge http://127.0.0.1:53220 verified",
                    "already elevated (no Terminal needed)",
                    "group apptun4821 (gid=57321)",
                    "60 rules in com.apple/apptunnel-4821",
                    "control probe reached 5/5 targets - test is meaningful",
                    "0/5 targets reachable directly - guard is enforcing", "", ""]
        for k in 0..<8 { m.phases[k] = .ok; m.phaseMsg[k] = msgs[k] }
        m.phases[8] = .running; m.currentPhase = 8
        m.phaseMsg[8] = "verifying the tunnel path"
        m.lastMessage = "0/5 targets reachable directly - guard is enforcing"
        for _ in 0..<90 { w.vis.step(); w.bars.step(); w.pos.step() }
        w.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                if let d = rep.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: out))
                    FileHandle.standardError.write("snapshot written: \(out)\n".data(using: .utf8)!)
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }

    /// Sonoma logs a warning on every launch when this is unanswered, and opts
    /// the app into the legacy insecure restorable-state path. We restore
    /// nothing from disk, so the secure coder is simply correct here.
    @available(macOS 12.0, *)
    func applicationSupportsSecureRestorableState(_ a: NSApplication) -> Bool { true }

    /// Clicking the Dock icon with the window hidden or minimised must bring it
    /// back. Without this the app looks gone while still running, because
    /// terminate-after-last-window is off.
    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = win { comeToFront(w) }
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
