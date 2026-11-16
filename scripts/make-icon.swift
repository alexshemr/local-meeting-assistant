// Рисует иконку приложения и сохраняет набор PNG для iconutil.
// Запуск: swift scripts/make-icon.swift <папка.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.42, blue: 0.95, alpha: 1),
                        NSColor(red: 0.10, green: 0.16, blue: 0.45, alpha: 1)])!.draw(in: shape, angle: -90)

    // Звуковая волна: вертикальные скруглённые столбики.
    let heights: [CGFloat] = [0.22, 0.48, 0.78, 0.36, 0.62, 0.30, 0.16]
    let barWidth = rect.width * 0.062
    let gap = rect.width * 0.048
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let barHeight = rect.height * h
        let bar = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(points * scale).write(to: output.appendingPathComponent(name))
}
