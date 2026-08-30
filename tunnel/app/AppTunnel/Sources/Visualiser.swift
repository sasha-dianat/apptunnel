// Visualiser.swift — the dancing unit in the top left.
//
// It used to be decoration: nineteen bars driven by random(), telling you
// nothing. Now it is the instrument. Ten bands, one per health factor, fed by
// the launcher's live sampler.
//
// A band at full height is healthy, so a FALLING bar is the alarm. That inverts
// the classic peak-hold into a VALLEY-hold: the red tick marks the worst value
// seen in the last half-minute, so a brief outage stays visible after it has
// recovered rather than silently healing.
//
// Click to cycle:
//   bands · radar · oscilloscope · signal path · latency history
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

    var mode = 0
    let modeCount = 6

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
        toolTip = "Live tunnel health. Click to cycle: neon · bands · radar · oscilloscope · signal path · latency history"
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

    func step() {
        let m = Model.shared
        let tel = m.telemetry

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
        let flow = live ? max(0, CGFloat(tel.values[6])) : 0
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
        case 1: live ? drawBands() : drawDeco()
        case 2: drawRadar()
        case 3: drawScope()
        case 4: drawCircuit()
        case 5: drawWaterfall()
        default: drawNeon()
        }
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

        let flow  = live ? max(0, CGFloat(tel.values[6])) : 0.08
        let score = live ? CGFloat(max(0, tel.score))     : 0.30

        // Smooth the ten discrete bands into a continuous surface.
        func surface(_ u: CGFloat) -> (CGFloat, NSColor) {
            let n = CGFloat(BANDS.count)
            let pos = min(max(u * (n - 1), 0), n - 1)
            let i0 = Int(pos), i1 = min(i0 + 1, BANDS.count - 1)
            let f = pos - CGFloat(i0)
            func val(_ k: Int) -> CGFloat {
                let v = live ? tel.values[k] : 0.55
                return v < 0 ? 0.35 : CGFloat(v)
            }
            // cosine interpolation keeps the surface smooth, not faceted
            let t2 = (1 - cos(f * .pi)) / 2
            let v = val(i0) * (1 - t2) + val(i1) * t2
            let dominant = f < 0.5 ? i0 : i1
            let dv = live ? tel.values[dominant] : 0.55
            let c: NSColor = !live ? NSColor(srgbRed: 0.15, green: 0.55, blue: 0.30, alpha: 1)
                : dv < 0 ? NSColor(white: 0.40, alpha: 1)
                : dv > 0.66 ? NSColor(srgbRed: 1.00, green: 0.85, blue: 0.25, alpha: 1)   // gold crest
                : dv > 0.33 ? Skin.amber
                : Skin.red
            return (v, c)
        }

        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.compositingOperation = .plusLighter

        let lines = 10 + Int(flow * 8)          // the field thickens under load
        let step: CGFloat = 3
        for k in 0..<lines {
            let kf = CGFloat(k) / CGFloat(max(lines - 1, 1))
            let depth = 0.35 + 0.65 * kf         // farther lines are dimmer
            let lift = kf * h * 0.34             // stacked to suggest a surface
            let phase = t * (0.010 + flow * 0.055) - kf * 1.5

            var prev: NSPoint? = nil
            var x: CGFloat = 0
            while x <= w {
                let u = x / w
                let (v, c) = surface(u)
                let swell = sin(u * .pi * 2.1 + phase) * (0.06 + 0.10 * flow) * h
                let y = 3 + lift + v * (h * 0.42) + swell
                let p = NSPoint(x: x, y: min(h - 1, y))
                if let q = prev {
                    let seg = NSBezierPath()
                    seg.lineCapStyle = .round
                    seg.move(to: q); seg.line(to: p)
                    // deep green body with a gold-tinted crest
                    let base = NSColor(srgbRed: 0.05, green: 0.75, blue: 0.35, alpha: 1)
                    let mixT = min(1, max(0, (y / h - 0.35) * 1.9))
                    let col = base.blended(withFraction: mixT * 0.9, of: c) ?? c
                    for (lw, a) in [(3.2, 0.05), (1.8, 0.10), (0.9, 0.30)] {
                        col.withAlphaComponent(CGFloat(a) * depth).setStroke()
                        seg.lineWidth = CGFloat(lw)
                        seg.stroke()
                    }
                }
                prev = p
                x += step
            }
        }
        ctx.restoreGraphicsState()

        // The pretty view still reports the number that matters.
        let sc: NSColor = !live ? NSColor(white: 0.28, alpha: 1)
                        : score <= 0.001 ? Skin.red
                        : score > 0.8 ? Skin.green : Skin.amber
        NSColor(white: 0.09, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: 2).fill()
        sc.setFill()
        NSRect(x: 0, y: 0, width: w * (live ? score : 0), height: 2).fill()
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
        let flow = max(0, CGFloat(tel.values[6]))
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
        let flow = live ? max(0, CGFloat(tel.values[6])) : 0

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
