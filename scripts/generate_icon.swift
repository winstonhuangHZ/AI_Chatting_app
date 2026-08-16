import AppKit
import Foundation

// 生成 1024×1024 应用图标（深蓝渐变圆角方形 + 白色聊天气泡 + 圆点）。
// 用法: swiftc -O scripts/generate_icon.swift -framework AppKit -o /tmp/genicon && /tmp/genicon <output.png>

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // 1) 圆角背景（深蓝→紫色渐变，带一点点高光）
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let corner: CGFloat = size * 0.22
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.13, green: 0.42, blue: 0.95, alpha: 1),
        CGColor(red: 0.38, green: 0.24, blue: 0.88, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // 2) 聊天气泡
    let bubble = CGRect(
        x: size * 0.18,
        y: size * 0.22,
        width: size * 0.64,
        height: size * 0.44
    )
    let bubblePath = CGPath(
        roundedRect: bubble,
        cornerWidth: size * 0.12,
        cornerHeight: size * 0.12,
        transform: nil
    )
    ctx.addPath(bubblePath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()

    // 气泡小尾巴
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: size * 0.28, y: bubble.minY))
    tail.addLine(to: CGPoint(x: size * 0.20, y: bubble.minY - size * 0.09))
    tail.addLine(to: CGPoint(x: size * 0.38, y: bubble.minY))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()

    // 3) 三个圆点（像打字中的气泡提示）
    let dotY = bubble.midY
    let dotR = size * 0.045
    let dotColors: [(CGFloat, CGFloat, CGFloat)] = [
        (0.13, 0.42, 0.95),
        (0.30, 0.62, 0.96),
        (0.55, 0.80, 0.99)
    ]
    for (i, c) in dotColors.enumerated() {
        let x = bubble.midX - dotR * 2.4 + CGFloat(i) * (dotR * 2.4)
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
    }

    image.unlockFocus()
    return image
}

// 输出 PNG
guard CommandLine.arguments.count >= 2 else {
    fputs("usage: genicon <output.png>\n", stderr)
    exit(1)
}
let outputPath = CommandLine.arguments[1]
let icon = drawIcon(size: 1024)

guard let tiff = icon.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render PNG\n", stderr)
    exit(1)
}

try! png.write(to: URL(fileURLWithPath: outputPath))
print("icon written: \(outputPath)")