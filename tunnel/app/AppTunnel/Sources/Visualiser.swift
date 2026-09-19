// Visualiser.swift — the instrument in the top left.
//
// It began as decoration: nineteen bars driven by random(), telling you
// nothing. It was then wired to the launcher's live sampler, which made the
// bars honest but did not make them legible - a moving bar graph still reads
// as a screensaver, and it cost a redraw plus a compositor pass thirty times a
// second to say "still fine".
//
// So the DEFAULT is now TRAFFIC: a bidirectional bandwidth graph, input filling
// up from a centre axis and output filling down, on one shared scale. The
// asymmetry is the reading - browsing is lopsided green, an upload flips it
// blue, a stalled tunnel is a flat line. Second is STATUS: four numbers and a
// word. Both redraw only when a displayed value changes, so a steady tunnel
// costs nothing between samples.
//
// The animated instruments are still here, one click away. Among them, a band
// at full height is healthy, so a FALLING bar is the alarm - a VALLEY-hold
// rather than the classic peak-hold, with the red tick marking the worst value
// of the last half-minute so a brief outage stays visible after it recovers.
//
// The radar is the one to watch. Ten spokes, one per factor, closed into a
// polygon: perfect health is a regular decagon, so the SHAPE is the reading -
// a dent points straight at whatever is failing before you read a label.
//
// And it MOVES with the traffic. Rotation is driven by throughput and the
// outline ripples with latency, so an idle tunnel sits still while a busy one
// comes alive. Motion here is data, not decoration.

import AppKit

final class Visualiser: NSView {
    var onHover: ((String?) -> Void)?

    // Modes 0 and 1 (TRAFFIC, STATUS) are event-driven readouts: they redraw
    // only when a displayed value moves. The rest are animated instruments -
    // real data, but a moving graph reads as decoration however honest it is,
    // and it costs a redraw plus a compositor pass thirty times a second to
    // say "still fine".
    var mode = 0
    let modeCount = 8
    private var statusSig = ""

    private var shown     = [CGFloat](repeating: 0.04, count: BANDS.count)
    private var valley    = [CGFloat](repeating: 1.0,  count: BANDS.count)
    private var valleyAge = [Int](repeating: 0, count: BANDS.count)

    // Decorative spectrum, used only while connecting (there is nothing to
    // measure yet, and a frozen panel would look broken).
    private let decoN = 19
    private var deco  = [CGFloat](repeating: 0, count: 19)
    private var peaks = [CGFloat](repeating: 0, count: 19)

    private var wave = [CGFloat](repeating: 0, count: 76)
    private var packets: [CGFloat] = [0, 0.25, 0.5, 0.75]
    private var t: CGFloat = 0
    private var spin: CGFloat = 0      // advanced by throughput
    private var ripple: CGFloat = 0    // advanced by latency
    private var hoverIndex: Int? = nil

    override init(frame f: NSRect) {
        super.init(frame: f)
        toolTip = "Network traffic: input above the axis, output below. Click to cycle: traffic · status · bands · radar · oscilloscope · signal path · latency history · neon"
        addTrackingArea(NSTrackingArea(rect: .zero,
                        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                        owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var live: Bool { Model.shared.telemetry.fresh }

    override func mouseDown(with e: NSEvent) {
        mode = (mode + 1) % modeCount
        needsDisplay = true
    }

    /// What STATUS shows, as one string. Redrawing is driven by this changing,
    /// so a steady tunnel costs nothing at all between samples.
    private func statusSignature() -> String {
        let m = Model.shared, tel = m.telemetry
        var bad = 0, warn = 0
        for i in 0..<BANDS.count {
            let v = tel.values[i]
            if v < 0 { continue }
            if v < 0.34 && !BANDS[i].idleIsFine { bad += 1 }
            else if v < 0.67 && !BANDS[i].idleIsFine { warn += 1 }
        }
        let rtt = tel.values.count > 5 ? Int(max(0, tel.values[5]) * 1000) : -1
        return "\(tel.fresh)|\(tel.exitIP)|\(bad)|\(warn)|\(rtt)|\(Int(m.net.bytesPerSecond / 1024))|\(m.sessionActive)"
    }

    func step() {
        let m = Model.shared
        let tel = m.telemetry

        // TRAFFIC and STATUS animate nothing. Skip every smoothing accumulator
        // below and only ask for a redraw when a displayed value actually moved.
        if mode <= 1 {
            let sig = mode == 0
                // Quantised to whole KB/s: the exact byte count changes on
                // every poll and would repaint the gradient trace continuously.
                ? "\(m.net.inHistory.count)|\(Int(m.net.inBytesPerSecond / 1024))|\(Int(m.net.outBytesPerSecond / 1024))"
                : statusSignature()
            if sig != statusSig { statusSig = sig; needsDisplay = true }
            return
        }

        for i in 0..<BANDS.count {
            let target: CGFloat = live
                ? (tel.values[i] < 0 ? 0.06 : max(0.04, CGFloat(tel.values[i])))
                : 0.04
            ease(&shown[i], target, 0.16)

            if shown[i] < valley[i] { valley[i] = shown[i]; valleyAge[i] = 0 }
            else {
                valleyAge[i] += 1
                if valleyAge[i] > 900 { valley[i] = min(1, valley[i] + 0.004) }
            }
        }

        // connecting animation
        let busy = m.connecting || m.demoMode
        let energy: CGFloat = busy ? 0.25 + CGFloat(m.completed) / CGFloat(PHASES.count) * 0.75 : 0.05
        for i in 0..<decoN {
            let base = sin(t / 6.5 + CGFloat(i) / 1.9) * 0.38 + 0.5
            let tilt = 1 - CGFloat(i) / CGFloat(decoN) / 1.6
            let target = busy ? max(0, base * energy * tilt + Render.rand(0.2) * energy)
                              : Render.rand(0.04)
            ease(&deco[i], target, 0.34)
            peaks[i] = max(peaks[i] - 0.011, deco[i])
        }

        for i in 0..<wave.count {
            let x = CGFloat(i) / CGFloat(wave.count)
            wave[i] = live ? sin(x * 12 + t / 4) * 0.34 + sin(x * 27 - t / 6) * 0.2
                           : sin(x * 6 + t / 9) * 0.02
        }

        // Packets travel faster when latency is low and stall when the tunnel
        // is down, so the motion itself carries information.
        let speed: CGFloat = live ? 0.004 + CGFloat(max(0, tel.values[5])) * 0.016 : 0
        for i in 0..<packets.count {
            packets[i] += speed
            if packets[i] > 1 { packets[i] -= 1 }
        }

        // The figure changes form with how hard the tunnel is working:
        // throughput turns it, latency ripples its outline. Idle means still.
        let flow = CGFloat(Model.shared.net.level)
        let rtt  = live ? max(0, CGFloat(tel.values[5])) : 0
        spin   += 0.002 + flow * 0.05
        ripple += 0.04 + rtt * 0.10

        t += 1
        needsDisplay = true
    }

    private func colour(_ i: Int) -> NSColor {
        let v = Model.shared.telemetry.values[i]
        if v < 0 { return NSColor(white: 0.34, alpha: 1) }          // unknown, never red
        if BANDS[i].idleIsFine && v < 0.15 { return Skin.greenDim } // idle FLOW is fine
        if v > 0.66 { return Skin.green }
        if v > 0.33 { return Skin.amber }
        return Skin.red
    }

    override func draw(_ r: NSRect) {
        Skin.lcd.setFill(); bounds.fill()
        switch mode {
        case 0: drawTraffic()
        case 1: drawStatus()
        case 2: live ? drawBands() : drawDeco()
        case 3: drawRadar()
        case 4: drawScope()
        case 5: drawCircuit()
        case 6: drawWaterfall()
        default: drawNeon()
        }
    }

    /// TRAFFIC — a bidirectional bandwidth graph.
    ///
    /// Input fills upward from a centre axis, output fills downward, both on one
    /// shared scale so the asymmetry between them is the reading: a browsing
    /// session is lopsided green, an upload flips it blue, and a stalled tunnel
    /// is a flat line through the middle. The scale is the window maximum, so
    /// the shape stays legible whether the link is doing 4 KB/s or 4 MB/s, with
    /// the peak printed so the height is never ambiguous.
    private func drawTraffic() {
        let net = Model.shared.net
        let labelH: CGFloat = 10
        let plotTop = bounds.height - labelH
        let mid = plotTop / 2
        let plotH = mid - 1.5

        func rate(_ b: Double) -> String {
            if b < 1000            { return String(format: "%.0f B/s", b) }
            if b < 1000 * 1024     { return String(format: "%.0f KB/s", b / 1024) }
            return String(format: "%.1f MB/s", b / 1024 / 1024)
        }

        // A three-tap mean. The kernel counters are read on a timer, so raw
        // samples are spiky in a way that says nothing about the link; smoothing
        // keeps the silhouette readable without inventing data.
        func smoothed(_ s: [Double]) -> [Double] {
            guard s.count > 2 else { return s }
            var o = s
            for i in 1..<(s.count - 1) { o[i] = (s[i-1] + s[i] * 2 + s[i+1]) / 4 }
            return o
        }
        let ins = smoothed(net.inHistory), outs = smoothed(net.outHistory)

        // Faint quarter gridlines, then the axis a little brighter.
        NSColor(white: 1, alpha: 0.05).setStroke()
        for f in [0.5 as CGFloat, 1.0] {
            for dir in [1.0 as CGFloat, -1.0] {
                let y = mid + dir * plotH * f
                let g = NSBezierPath()
                g.move(to: NSPoint(x: 0, y: y)); g.line(to: NSPoint(x: bounds.width, y: y))
                g.lineWidth = 1; g.stroke()
            }
        }
        NSColor(white: 1, alpha: 0.16).setStroke()
        let ax = NSBezierPath()
        ax.move(to: NSPoint(x: 0, y: mid)); ax.line(to: NSPoint(x: bounds.width, y: mid))
        ax.lineWidth = 1; ax.stroke()

        guard ins.count > 1 else {
            let f = Skin.mono(8, false)
            let s = "listening for traffic"
            let w = (s as NSString).size(withAttributes: [.font: f]).width
            text(s, NSPoint(x: (bounds.width - w) / 2, y: mid - 5), f, Skin.metalHi)
            return
        }

        // One shared scale, with a 16 KB/s floor so an idle link is a calm flat
        // line rather than amplified noise.
        let peak = max(ins.max() ?? 0, outs.max() ?? 0, 16 * 1024)
        let dx = bounds.width / CGFloat(ThroughputMeter.historyLen - 1)

        func area(_ series: [Double], up: Bool, _ tint: NSColor) {
            guard series.count > 1 else { return }
            // Right-aligned: newest sample at the right edge, so the graph grows
            // leftwards into history instead of stretching as it fills.
            let x0 = bounds.width - CGFloat(series.count - 1) * dx
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: mid))
            for (i, v) in series.enumerated() {
                let h = CGFloat(min(1.0, v / peak)) * plotH
                p.line(to: NSPoint(x: x0 + CGFloat(i) * dx, y: up ? mid + h : mid - h))
            }
            p.line(to: NSPoint(x: bounds.width, y: mid))
            p.close()

            // Gradient body: saturated at the axis, fading out toward the peak,
            // so overlapping traces stay legible and the baseline reads as the
            // anchor rather than the edge.
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            let g = NSGradient(colors: [tint.withAlphaComponent(0.55),
                                        tint.withAlphaComponent(0.06)])
            g?.draw(in: NSRect(x: 0, y: up ? mid : mid - plotH,
                               width: bounds.width, height: plotH),
                    angle: up ? 90 : -90)
            NSGraphicsContext.restoreGraphicsState()

            // Bright hairline along the top of the trace only.
            let line = NSBezierPath()
            for (i, v) in series.enumerated() {
                let h = CGFloat(min(1.0, v / peak)) * plotH
                let pt = NSPoint(x: x0 + CGFloat(i) * dx, y: up ? mid + h : mid - h)
                i == 0 ? line.move(to: pt) : line.line(to: pt)
            }
            line.lineWidth = 1
            line.lineJoinStyle = .round
            tint.withAlphaComponent(0.9).setStroke()
            line.stroke()
        }
        area(ins,  up: true,  Skin.green)
        area(outs, up: false, Skin.cyan)

        // Header: a colour chip per direction with its current rate, and the
        // scale on the right so a tall trace is never ambiguous.
        let f = Skin.mono(8, false)
        let y = bounds.height - labelH + 1
        func chip(_ x: CGFloat, _ c: NSColor, _ s: String) -> CGFloat {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y + 2, width: 4, height: 4)).fill()
            text(s, NSPoint(x: x + 7, y: y), f, Skin.label)
            return x + 7 + (s as NSString).size(withAttributes: [.font: f]).width + 9
        }
        let nx = chip(4, Skin.green, rate(net.inBytesPerSecond))
        _ = chip(nx, Skin.cyan, rate(net.outBytesPerSecond))
        let pk = rate(peak)
        let pw = (pk as NSString).size(withAttributes: [.font: f]).width
        text(pk, NSPoint(x: bounds.width - pw - 4, y: y), f, Skin.metalHi)
    }

    /// STATUS — the readout, not the light show.
    ///
    /// Answers the four questions the panel is actually consulted for: is the
    /// tunnel carrying traffic, where does it come out, how far away is that,
    /// and is anything unhealthy. Everything is a number or a word; the only
    /// graphic is a ten-dot strip, one dot per factor, so a fault still points
    /// at itself without needing a shape to be decoded.
    private func drawStatus() {
        let m = Model.shared, tel = m.telemetry
        let small = Skin.mono(8, true)
        let big   = Skin.mono(11, true)

        var bad = 0, warn = 0
        for i in 0..<BANDS.count {
            let v = tel.values[i]
            if v < 0 || BANDS[i].idleIsFine { continue }
            if v < 0.34 { bad += 1 } else if v < 0.67 { warn += 1 }
        }

        let word: String
        let tint: NSColor
        if !tel.fresh      { word = "NO DATA";  tint = Skin.label }
        else if bad > 0    { word = "FAULT";    tint = Skin.red }
        else if warn > 0   { word = "DEGRADED"; tint = Skin.amber }
        else               { word = "SECURE";   tint = Skin.green }
        text(word, NSPoint(x: 8, y: bounds.height - 16), big, tint)

        // Ten dots, one per factor. Position is the band, colour is its health.
        let dotY = bounds.height - 26
        for i in 0..<BANDS.count {
            let v = tel.values[i]
            let c: NSColor = !tel.fresh || v < 0 ? Skin.metalHi
                           : (BANDS[i].idleIsFine || v >= 0.67) ? Skin.greenMid
                           : v >= 0.34 ? Skin.amber : Skin.red
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: 8 + CGFloat(i) * 9, y: dotY, width: 5, height: 5)).fill()
        }

        let ip = tel.exitIP.isEmpty ? "—" : tel.exitIP
        text("EXIT \(ip)", NSPoint(x: 8, y: dotY - 13), small, Skin.label)

        let rttMs = tel.values.count > 5 && tel.values[5] >= 0 ? Int(tel.values[5] * 1000) : -1
        let rttStr = rttMs < 0 ? "—" : "\(rttMs)ms"
        let kb = m.net.bytesPerSecond / 1024.0
        let flow = kb < 1 ? "idle" : (kb < 1024 ? String(format: "%.0f KB/s", kb)
                                                : String(format: "%.1f MB/s", kb / 1024))
        text("RTT \(rttStr)   FLOW \(flow)", NSPoint(x: 8, y: dotY - 24), small, Skin.label)
    }

    // MARK: modes

    /// A field of flowing lines whose SURFACE is the ten-band health profile.
    ///
    /// The curve at any horizontal position is that factor's value, smoothed
    /// between neighbours — so the silhouette you see is literally the reading.
    /// A dip in the wave is a dip in health, and it sits above the band that
    /// caused it.
    ///
    ///   travel speed  = throughput   (idle is almost still, busy streams)
    ///   crest colour  = that factor  (gold healthy, amber soft, red failing)
    ///   line count    = throughput   (the field thickens under load)
    ///
    /// Glow comes from stacking translucent strokes with additive compositing,
    /// which is cheap enough to hold 30fps on this small canvas.
    private func drawNeon() {
        let tel = Model.shared.telemetry
        let w = bounds.width, h = bounds.height

        // Real measured bandwidth, not a connection count.
        let flow  = CGFloat(Model.shared.net.level)
        let score = live ? CGFloat(max(0, tel.score)) : 0.55

        func bandValue(_ k: Int) -> CGFloat {
            let v = live ? tel.values[k] : 0.62
            return v < 0 ? 0.35 : CGFloat(v)
        }
        func bandColour(_ k: Int) -> NSColor {
            let v = live ? tel.values[k] : 0.62
            if v < 0 { return NSColor(white: 0.45, alpha: 1) }
            if v > 0.66 { return NSColor(srgbRed: 1.00, green: 0.90, blue: 0.35, alpha: 1) }
            if v > 0.33 { return Skin.amber }
            return Skin.red
        }
        func surface(_ u: CGFloat) -> CGFloat {
            let n = CGFloat(BANDS.count)
            let pos = min(max(u * (n - 1), 0), n - 1)
            let i0 = Int(pos), i1 = min(i0 + 1, BANDS.count - 1)
            let f = (1 - cos((pos - CGFloat(i0)) * .pi)) / 2
            return bandValue(i0) * (1 - f) + bandValue(i1) * f
        }

        // A standby panel should look asleep, not broken. Off state gets its own
        // cool palette and a faint wash so the unit still reads as a display
        // rather than a black hole; green is reserved for "protected".
        let wash = NSGradient(colors: live
            ? [NSColor(srgbRed: 0.02, green: 0.09, blue: 0.05, alpha: 1), Skin.lcd]
            : [NSColor(srgbRed: 0.04, green: 0.08, blue: 0.14, alpha: 1), Skin.lcd])
        wash?.draw(in: bounds, angle: -90)

        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.compositingOperation = .plusLighter

        let lines = live ? 9 + Int(flow * 9) : 7
        let step: CGFloat = 3
        let emerald = live
            ? NSColor(srgbRed: 0.10, green: 0.95, blue: 0.45, alpha: 1)
            : NSColor(srgbRed: 0.25, green: 0.65, blue: 1.00, alpha: 1)   // standby blue

        for k in 0..<lines {
            let kf = CGFloat(k) / CGFloat(max(lines - 1, 1))
            let depth = 0.30 + 0.70 * kf
            let lift = kf * h * 0.32
            let phase = (live ? t * (0.008 + flow * 0.075) : t * 0.006) - kf * 1.6

            // one path per line, so the halo can be stroked in wide passes
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            var x: CGFloat = 0
            while x <= w {
                let u = x / w
                let swell = sin(u * .pi * 2.1 + phase) * (0.05 + 0.13 * flow) * h
                let y = min(h - 1, 3 + lift + surface(u) * (h * 0.40) + swell)
                x == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
                x += step
            }

            // HALO: wide, faint passes first. This is what was missing - three
            // thin strokes at 5% alpha read as a hairline, not a glow.
            let boost: CGFloat = live ? (0.75 + 0.45 * flow) : 1.15
            for (lw, a) in [(11.0, 0.030), (7.0, 0.045), (4.0, 0.075), (2.4, 0.130)] {
                emerald.withAlphaComponent(CGFloat(a) * depth * boost).setStroke()
                path.lineWidth = CGFloat(lw)
                path.stroke()
            }

            // CORE: bright, thin, and tinted per band so the crest still says
            // which factor sits under it.
            var cx: CGFloat = 0
            while cx < w {
                let u = cx / w
                let k2 = min(BANDS.count - 1, Int(u * CGFloat(BANDS.count)))
                let seg = NSBezierPath()
                seg.lineCapStyle = .round
                var first = true
                var sx = cx
                let end = min(w, cx + w / CGFloat(BANDS.count))
                while sx <= end {
                    let uu = sx / w
                    let swell = sin(uu * .pi * 2.1 + phase) * (0.05 + 0.13 * flow) * h
                    let y = min(h - 1, 3 + lift + surface(uu) * (h * 0.40) + swell)
                    let p = NSPoint(x: sx, y: y)
                    first ? seg.move(to: p) : seg.line(to: p)
                    first = false
                    sx += step
                }
                let core = live ? bandColour(k2)
                                : NSColor(srgbRed: 0.55, green: 0.85, blue: 1.0, alpha: 1)
                core.withAlphaComponent(0.55 * depth + (live ? 0.35 : 0.22)).setStroke()
                seg.lineWidth = 1.1
                seg.stroke()
                cx = end
            }
        }
        ctx.restoreGraphicsState()

        if !live {
            let f = Skin.mono(6)
            let msg = "STANDBY"
            text(msg, NSPoint(x: w - width(msg, f) - 4, y: h - 9), f,
                 NSColor(srgbRed: 0.40, green: 0.65, blue: 0.90, alpha: 1))
        }
        let sc: NSColor = !live ? NSColor(srgbRed: 0.20, green: 0.40, blue: 0.62, alpha: 1)
                        : score <= 0.001 ? Skin.red
                        : score > 0.8 ? Skin.green : Skin.amber
        NSColor(white: 0.09, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: 2).fill()
        sc.setFill()
        NSRect(x: 0, y: 0, width: w * (live ? score : 0.18), height: 2).fill()
    }

    /// An electric spectrum analyser where BOTH axes carry meaning.
    ///
    ///   height = how healthy that factor is
    ///   width  = how hard the tunnel is working (throughput)
    ///
    /// So the display physically swells as bandwidth rises: thin, still bars on
    /// an idle tunnel; fat, arcing ones when it is moving data.
    private func drawBands() {
        let tel = Model.shared.telemetry
        let strip: CGFloat = 5
        let top = bounds.height - 2
        let base = strip + 2
        let h = top - base
        let slot = bounds.width / CGFloat(BANDS.count)
        let flow = CGFloat(Model.shared.net.level)
        var tops: [NSPoint] = []

        for i in 0..<BANDS.count {
            let cx = slot * (CGFloat(i) + 0.5)
            let breathe = 1 + sin(ripple * 0.6 + CGFloat(i) * 0.8) * 0.12 * flow
            let w: CGFloat = max(2, (slot * (0.22 + 0.62 * flow)) * breathe)
            let c = colour(i)
            let bh = max(1, h * shown[i])
            tops.append(NSPoint(x: cx, y: base + bh))

            if hoverIndex == i {
                NSColor(white: 0.16, alpha: 1).setFill()
                NSRect(x: cx - slot / 2, y: base - 1, width: slot, height: h + 2).fill()
            }

            var y: CGFloat = base
            while y < base + bh {
                c.withAlphaComponent(0.45 + 0.55 * ((y - base) / max(h, 1))).setFill()
                NSRect(x: cx - w / 2, y: y, width: w, height: 1).fill()
                y += 2
            }

            if valley[i] < 0.95 {
                Skin.red.withAlphaComponent(0.9).setFill()
                NSRect(x: cx - w / 2 - 1, y: base + h * valley[i], width: w + 2, height: 1).fill()
            }
            if flow > 0.05 {
                c.withAlphaComponent(0.25 + 0.55 * flow).setFill()
                NSRect(x: cx - w / 2 - 1, y: base + bh - 1, width: w + 2, height: 2).fill()
            }
        }

        // Electric arc across the tops; its jitter scales with throughput.
        if flow > 0.05, tops.count > 1 {
            let arc = NSBezierPath(); arc.lineWidth = 1
            for (i, p) in tops.enumerated() {
                let j = sin(ripple * 1.7 + CGFloat(i) * 2.3) * 2.5 * flow
                let q = NSPoint(x: p.x, y: min(top, p.y + 2 + j))
                i == 0 ? arc.move(to: q) : arc.line(to: q)
            }
            Skin.green.withAlphaComponent(0.30 + 0.5 * flow).setStroke()
            arc.stroke()
        }

        let s = CGFloat(max(0, tel.score))
        let sc: NSColor = tel.score < 0 ? NSColor(white: 0.3, alpha: 1)
                        : s <= 0.001 ? Skin.red : s > 0.8 ? Skin.green : Skin.amber
        NSColor(white: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: strip - 1).fill()
        sc.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * s, height: strip - 1).fill()
    }

    /// Ten spokes closed into a polygon: healthy is a regular decagon, so a
    /// dent names the fault by direction. It rotates with throughput and its
    /// outline breathes with latency.
    private func drawRadar() {
        let tel = Model.shared.telemetry
        let cx = bounds.midX, cy = bounds.midY
        let rMax = min(bounds.width, bounds.height) / 2 - 5
        let n = BANDS.count
        let flow = CGFloat(Model.shared.net.level)

        func point(_ i: Int, _ frac: CGFloat, _ wobble: CGFloat = 0) -> NSPoint {
            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * CGFloat.pi / CGFloat(n) + spin
            let r = rMax * frac * (1 + wobble)
            return NSPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
        }

        let ref = NSBezierPath(); ref.lineWidth = 1
        for i in 0..<n {
            let p = point(i, 1)
            i == 0 ? ref.move(to: p) : ref.line(to: p)
        }
        ref.close()
        NSColor(srgbRed: 0.06, green: 0.20, blue: 0.08, alpha: 1).setStroke(); ref.stroke()

        NSColor(white: 0.13, alpha: 1).setStroke()
        for i in 0..<n {
            let sp = NSBezierPath(); sp.lineWidth = 1
            sp.move(to: NSPoint(x: cx, y: cy)); sp.line(to: point(i, 1)); sp.stroke()
        }

        guard live else {
            let f = Skin.mono(6)
            text("no signal", NSPoint(x: cx - width("no signal", f) / 2, y: cy - 3), f, Skin.greenDim)
            return
        }

        let poly = NSBezierPath()
        for i in 0..<n {
            let v = tel.values[i]
            let frac = v < 0 ? 0.12 : max(0.08, CGFloat(v))
            let wob = sin(ripple + CGFloat(i) * 0.9) * 0.06 * flow
            let p = point(i, frac, wob)
            i == 0 ? poly.move(to: p) : poly.line(to: p)
        }
        poly.close()

        let s = CGFloat(max(0, tel.score))
        let fillC: NSColor = tel.score < 0 ? NSColor(white: 0.3, alpha: 1)
                           : s <= 0.001 ? Skin.red : s > 0.8 ? Skin.green : Skin.amber
        fillC.withAlphaComponent(0.20 + 0.18 * flow).setFill(); poly.fill()
        fillC.setStroke(); poly.lineWidth = 1.5; poly.stroke()

        for i in 0..<n {
            let v = tel.values[i]
            let frac = v < 0 ? 0.12 : max(0.08, CGFloat(v))
            let wob = sin(ripple + CGFloat(i) * 0.9) * 0.06 * flow
            let p = point(i, frac, wob)
            colour(i).setFill()
            NSRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3).fill()
        }
    }

    /// While connecting there is nothing to measure yet, so keep it alive.
    private func drawDeco() {
        let bw = bounds.width / CGFloat(decoN)
        let h = bounds.height - 3
        for i in 0..<decoN {
            let x = CGFloat(i) * bw + 1
            var y: CGFloat = 1
            let bh = max(1, deco[i] * h)
            while y < bh {
                let f = y / h
                (f > 0.74 ? Skin.red : f > 0.46 ? Skin.amber : Skin.green)
                    .withAlphaComponent(0.5 + f * 0.5).setFill()
                NSRect(x: x, y: y, width: bw - 2, height: 1).fill()
                y += 2
            }
            NSColor(white: 0.75, alpha: 0.85).setFill()
            NSRect(x: x, y: 1 + peaks[i] * h, width: bw - 2, height: 1).fill()
        }
    }

    private func drawScope() {
        let mid = bounds.midY
        let path = NSBezierPath(); path.lineWidth = 1
        let amp = bounds.height / 2 - 2
        for i in 0..<wave.count {
            let x = bounds.minX + CGFloat(i) / CGFloat(wave.count - 1) * bounds.width
            let y = mid + wave[i] * amp
            i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        (live ? Skin.green : Skin.greenDim).setStroke()
        path.stroke()
    }

    /// The actual signal path. A hop reddens when its band fails, so you can
    /// see WHERE the tunnel is broken, not merely that it is.
    private func drawCircuit() {
        let tel = Model.shared.telemetry
        let hops = [("APP", 9), ("BRDG", 3), ("SOX", 2), ("EXIT", 4)]
        let y = bounds.midY + 4
        let pad: CGFloat = 14
        let span = bounds.width - pad * 2
        let step = span / CGFloat(hops.count - 1)

        for i in 0..<(hops.count - 1) {
            let v = live ? tel.values[hops[i + 1].1] : -1
            let c: NSColor = v < 0 ? NSColor(white: 0.3, alpha: 1)
                           : v > 0.66 ? Skin.greenMid : v > 0.33 ? Skin.amber : Skin.red
            c.setStroke()
            let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: NSPoint(x: pad + step * CGFloat(i), y: y))
            p.line(to: NSPoint(x: pad + step * CGFloat(i + 1), y: y))
            p.stroke()
        }

        if live {
            for pos in packets {
                Skin.green.withAlphaComponent(0.9).setFill()
                NSRect(x: pad + span * pos - 1.5, y: y - 1.5, width: 3, height: 3).fill()
            }
        }

        let f = Skin.mono(6)
        for (i, hop) in hops.enumerated() {
            let x = pad + step * CGFloat(i)
            let v = live ? tel.values[hop.1] : -1
            let c: NSColor = v < 0 ? NSColor(white: 0.35, alpha: 1)
                           : v > 0.66 ? Skin.green : v > 0.33 ? Skin.amber : Skin.red
            c.setFill()
            NSRect(x: x - 4, y: y - 4, width: 8, height: 8).fill()
            text(hop.0, NSPoint(x: x - width(hop.0, f) / 2, y: y - 16), f, c)
        }
    }

    /// Latency history, newest on the right — a seismograph for the tunnel.
    private func drawWaterfall() {
        let h = Model.shared.telemetry.history
        let f = Skin.mono(6)
        guard !h.isEmpty else {
            text("no samples yet", NSPoint(x: 5, y: bounds.midY - 3), f, Skin.greenDim)
            return
        }
        let n = min(h.count, Int(bounds.width))
        let slice = Array(h.suffix(n))
        let colW = bounds.width / CGFloat(n)
        for (i, v) in slice.enumerated() {
            let bh = max(1, CGFloat(v) * (bounds.height - 8))
            let c: NSColor = v > 0.66 ? Skin.green : v > 0.33 ? Skin.amber : Skin.red
            c.withAlphaComponent(0.85).setFill()
            NSRect(x: CGFloat(i) * colW, y: 1, width: max(1, colW - 0.5), height: bh).fill()
        }
        text("RTT", NSPoint(x: 3, y: bounds.height - 9), f, Skin.greenDim)
    }

    // MARK: hover

    override func mouseMoved(with e: NSEvent) {
        guard mode == 0, live else {
            if hoverIndex != nil { hoverIndex = nil; needsDisplay = true; onHover?(nil) }
            return
        }
        let p = convert(e.locationInWindow, from: nil)
        let slot = bounds.width / CGFloat(BANDS.count)
        let i = Int(p.x / slot)
        let idx = (i >= 0 && i < BANDS.count) ? i : nil
        if idx != hoverIndex {
            hoverIndex = idx
            needsDisplay = true
            onHover?(idx.map(describe))
        }
    }
    override func mouseExited(with e: NSEvent) {
        hoverIndex = nil; needsDisplay = true; onHover?(nil)
    }

    private func describe(_ i: Int) -> String {
        let tel = Model.shared.telemetry
        let b = BANDS[i]
        let v = tel.values[i]
        let d = tel.details[i]
        let state = v < 0 ? "unknown" : v > 0.66 ? "good" : v > 0.33 ? "degraded" : "FAILING"
        return "\(b.label) — \(state)\(d.isEmpty ? "" : " · \(d)")"
    }
}
