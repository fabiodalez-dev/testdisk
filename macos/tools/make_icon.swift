// Renders the Ritrovo icon: swift tools/make_icon.swift <out.iconset>
// Graphite tile, paper symbol, one copper detail (see DESIGN.md).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let graphiteTop = NSColor(srgbRed: 0.205, green: 0.187, blue: 0.172, alpha: 1)
let graphiteBottom = NSColor(srgbRed: 0.120, green: 0.108, blue: 0.098, alpha: 1)
let paper = NSColor(srgbRed: 0.955, green: 0.940, blue: 0.918, alpha: 1)
let copper = NSColor(srgbRed: 0.845, green: 0.575, blue: 0.387, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: graphiteTop, ending: graphiteBottom)!.draw(in: tile, angle: -90)
    // hairline edge
    paper.withAlphaComponent(0.10).setStroke()
    tile.lineWidth = max(1, s / 256)
    tile.stroke()

    // Two stacked prints, paper colored, slightly rotated
    let w = rect.width * 0.50, h = w * 0.78
    let center = NSPoint(x: s / 2, y: s / 2 - s * 0.01)
    func print(_ angle: CGFloat, _ dx: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, image: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: center.x + dx, yBy: center.y + dy)
        t.rotate(byDegrees: angle)
        t.concat()
        let frame = NSRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let card = NSBezierPath(roundedRect: frame, xRadius: w * 0.05, yRadius: w * 0.05)
        paper.withAlphaComponent(alpha).setFill()
        card.fill()
        if image {
            let inner = frame.insetBy(dx: w * 0.07, dy: w * 0.07)
            let pic = NSBezierPath(roundedRect: inner, xRadius: w * 0.025, yRadius: w * 0.025)
            graphiteBottom.setFill()
            pic.fill()
            // hills
            let hills = NSBezierPath()
            hills.move(to: NSPoint(x: inner.minX, y: inner.minY))
            hills.line(to: NSPoint(x: inner.minX + inner.width * 0.36, y: inner.minY + inner.height * 0.48))
            hills.line(to: NSPoint(x: inner.minX + inner.width * 0.56, y: inner.minY + inner.height * 0.24))
            hills.line(to: NSPoint(x: inner.minX + inner.width * 0.72, y: inner.minY + inner.height * 0.40))
            hills.line(to: NSPoint(x: inner.maxX, y: inner.minY + inner.height * 0.10))
            hills.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            hills.close()
            paper.withAlphaComponent(0.22).setFill()
            hills.fill()
            // copper sun: the one accent
            let r = inner.width * 0.11
            copper.setFill()
            NSBezierPath(ovalIn: NSRect(x: inner.maxX - inner.width * 0.27, y: inner.maxY - inner.height * 0.40, width: r * 2, height: r * 2)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    print(-9, -s * 0.035, s * 0.03, 0.28, image: false)
    print(4, s * 0.02, -s * 0.02, 1.0, image: true)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
