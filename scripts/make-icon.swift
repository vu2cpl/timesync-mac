// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics

// 1024x1024 master icon for TimeSync
// - Squircle background with vertical blue gradient
// - White clock face with hour markers and hands at 10:10:00
// - Small green satellite signal in the upper-right
//
// Run with: swift /tmp/make-icon.swift /tmp/icon-1024.png

let outPath = CommandLine.arguments.dropFirst().first ?? "/tmp/icon-1024.png"
let size: CGFloat = 1024

guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil,
                          width: Int(size),
                          height: Int(size),
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("ctx create failed\n", stderr); exit(1)
}

// Flip Y so we can draw in "natural" coordinates
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// --- 1. Squircle background with gradient -------------------------------------
let cornerRadius: CGFloat = size * 0.225  // matches Apple's "continuous corner" rounding
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let squircle = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Vertical gradient: navy → cobalt
let topColor = CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 1)        // #0A2342
let botColor = CGColor(red: 0.12, green: 0.53, blue: 0.90, alpha: 1)        // #1E88E5
if let grad = CGGradient(colorsSpace: cs, colors: [topColor, botColor] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(grad,
                            start: CGPoint(x: size / 2, y: size),
                            end:   CGPoint(x: size / 2, y: 0),
                            options: [])
}
ctx.restoreGState()

// --- 2. Clock face ------------------------------------------------------------
let center = CGPoint(x: size / 2, y: size / 2)
let faceR: CGFloat = size * 0.36

// White face with subtle inner ring for definition
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - faceR, y: center.y - faceR,
                            width: faceR * 2, height: faceR * 2))
ctx.setStrokeColor(CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 0.15))
ctx.setLineWidth(size * 0.005)
ctx.strokeEllipse(in: CGRect(x: center.x - faceR, y: center.y - faceR,
                              width: faceR * 2, height: faceR * 2))
ctx.restoreGState()

// 12 hour-marker dots
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 1))
let markerR = size * 0.012
let markerOrbit = faceR * 0.85
for h in 0..<12 {
    // 12 o'clock is straight up; angle increases clockwise
    let angle = CGFloat(h) * (.pi / 6) - (.pi / 2)
    let x = center.x + markerOrbit * cos(angle)
    let y = center.y + markerOrbit * sin(angle)
    let r: CGFloat = (h % 3 == 0) ? markerR * 1.6 : markerR  // 12/3/6/9 are larger
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}
ctx.restoreGState()

// Clock hands at 10:10:00
// Hour hand: 10 o'clock = -60°  (i.e., 300° / 5*30°)
// Minute hand: 10 minutes = 60°  (i.e., 2*30°, pointing to 2 on the dial — but minute hand at "10" position is 2 o'clock direction)
// Actually 10:10 means hour=10, minute=10 → minute hand points at "2" (10/60 * 360 = 60° from top)
let hourAngle: CGFloat = (10.0 / 12.0) * 2 * .pi - .pi / 2 + (10.0 / 60.0) * (2 * .pi / 12)
let minuteAngle: CGFloat = (10.0 / 60.0) * 2 * .pi - .pi / 2
let hourLen = faceR * 0.55
let minuteLen = faceR * 0.78

ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 1))
ctx.setLineCap(.round)

// Hour hand (thicker)
ctx.setLineWidth(size * 0.03)
ctx.move(to: center)
ctx.addLine(to: CGPoint(x: center.x + hourLen * cos(hourAngle),
                         y: center.y + hourLen * sin(hourAngle)))
ctx.strokePath()

// Minute hand
ctx.setLineWidth(size * 0.022)
ctx.move(to: center)
ctx.addLine(to: CGPoint(x: center.x + minuteLen * cos(minuteAngle),
                         y: center.y + minuteLen * sin(minuteAngle)))
ctx.strokePath()
ctx.restoreGState()

// Center pin
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 1))
let pinR = size * 0.018
ctx.fillEllipse(in: CGRect(x: center.x - pinR, y: center.y - pinR,
                            width: pinR * 2, height: pinR * 2))
ctx.restoreGState()

// --- 3. GPS satellite + orbit ring -------------------------------------------
// A dashed orbit ring around the clock face, with a stylized satellite (body +
// solar panel wings) parked at upper-right of the orbit. Signal lines from the
// satellite toward the clock center make the "satellite tells the clock time"
// motif explicit.
let orbitR = faceR * 1.18
let accentColor = CGColor(red: 0.30, green: 1.0, blue: 0.55, alpha: 1)        // bright cyan-green
let accentSoft  = CGColor(red: 0.30, green: 1.0, blue: 0.55, alpha: 0.55)

// Orbit ring (dashed)
ctx.saveGState()
ctx.setStrokeColor(accentSoft)
ctx.setLineWidth(size * 0.006)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [size * 0.018, size * 0.014])
ctx.strokeEllipse(in: CGRect(x: center.x - orbitR, y: center.y - orbitR,
                              width: orbitR * 2, height: orbitR * 2))
ctx.restoreGState()

// Satellite position on orbit (upper-right, roughly 1 o'clock direction)
let satAngle: CGFloat = -.pi / 2 + (2.0 / 12.0) * 2 * .pi  // 2 o'clock-ish
let satCenter = CGPoint(x: center.x + orbitR * cos(satAngle),
                         y: center.y + orbitR * sin(satAngle))

// Signal lines: three short rays from satellite toward clock center
ctx.saveGState()
ctx.setStrokeColor(accentSoft)
ctx.setLineCap(.round)
ctx.setLineWidth(size * 0.007)
ctx.setLineDash(phase: 0, lengths: [size * 0.015, size * 0.012])
let beamDir = CGPoint(x: center.x - satCenter.x, y: center.y - satCenter.y)
let beamLen = sqrt(beamDir.x * beamDir.x + beamDir.y * beamDir.y)
let beamUnit = CGPoint(x: beamDir.x / beamLen, y: beamDir.y / beamLen)
// Three parallel beams, slightly offset perpendicular
let perp = CGPoint(x: -beamUnit.y, y: beamUnit.x)
for offset in [-1.0, 0.0, 1.0] as [CGFloat] {
    let off = offset * size * 0.018
    ctx.move(to: CGPoint(x: satCenter.x + perp.x * off + beamUnit.x * (size * 0.04),
                          y: satCenter.y + perp.y * off + beamUnit.y * (size * 0.04)))
    ctx.addLine(to: CGPoint(x: satCenter.x + perp.x * off + beamUnit.x * (beamLen - size * 0.05),
                             y: satCenter.y + perp.y * off + beamUnit.y * (beamLen - size * 0.05)))
}
ctx.strokePath()
ctx.restoreGState()

// Satellite — rotated to face the clock (long axis perpendicular to beam)
ctx.saveGState()
ctx.translateBy(x: satCenter.x, y: satCenter.y)
// Rotate so the satellite "body" is perpendicular to the beam direction
ctx.rotate(by: atan2(beamUnit.y, beamUnit.x) + .pi / 2)

let bodyW = size * 0.06
let bodyH = size * 0.08
// Body (rectangle, rounded)
ctx.setFillColor(accentColor)
let bodyPath = CGPath(roundedRect: CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH),
                       cornerWidth: size * 0.008,
                       cornerHeight: size * 0.008,
                       transform: nil)
ctx.addPath(bodyPath)
ctx.fillPath()

// Two solar-panel wings (trapezoidal-ish — drawn as rectangles for clarity)
let wingW = size * 0.085
let wingH = size * 0.05
ctx.setFillColor(CGColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1))   // slightly darker green for panels
let leftWing = CGRect(x: -bodyW / 2 - wingW, y: -wingH / 2, width: wingW, height: wingH)
let rightWing = CGRect(x: bodyW / 2,         y: -wingH / 2, width: wingW, height: wingH)
ctx.fill(leftWing)
ctx.fill(rightWing)

// Solar-panel grid lines (3 vertical lines per panel) for "panel" texture
ctx.setStrokeColor(CGColor(red: 0.04, green: 0.14, blue: 0.32, alpha: 0.55))
ctx.setLineWidth(size * 0.003)
for wing in [leftWing, rightWing] {
    for i in 1...2 {
        let x = wing.minX + (wing.width / 3) * CGFloat(i)
        ctx.move(to: CGPoint(x: x, y: wing.minY))
        ctx.addLine(to: CGPoint(x: x, y: wing.maxY))
    }
}
ctx.strokePath()

// Tiny antenna nub on top of body
ctx.setStrokeColor(accentColor)
ctx.setLineWidth(size * 0.006)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 0, y: -bodyH / 2))
ctx.addLine(to: CGPoint(x: 0, y: -bodyH / 2 - size * 0.025))
ctx.strokePath()

ctx.restoreGState()

// --- 4. Save to PNG -----------------------------------------------------------
guard let cgImage = ctx.makeImage() else {
    fputs("makeImage failed\n", stderr); exit(1)
}
let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
guard let tiffData = nsImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiffData),
      let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(pngData.count) bytes to \(outPath)")
} catch {
    fputs("write failed: \(error)\n", stderr); exit(1)
}
