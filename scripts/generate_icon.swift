import AppKit
import Foundation

// 生成 1024×1024 应用图标。
// 设计：Big Sur 规范圆角矩形，深靛蓝→紫罗兰渐变，白色聊天气泡内嵌 AI 星光。
// 用法: swiftc -O scripts/generate_icon.swift -framework AppKit -o /tmp/genicon && /tmp/genicon <output.png>

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

private func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: locations
    )!
}

/// Four-point "AI sparkle" with concave sides.
private func sparklePath(center: CGPoint, radius: CGFloat, waist: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let top = CGPoint(x: center.x, y: center.y + radius)
    let right = CGPoint(x: center.x + radius, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y - radius)
    let left = CGPoint(x: center.x - radius, y: center.y)
    let c1 = CGPoint(x: center.x + waist, y: center.y + waist)
    let c2 = CGPoint(x: center.x + waist, y: center.y - waist)
    let c3 = CGPoint(x: center.x - waist, y: center.y - waist)
    let c4 = CGPoint(x: center.x - waist, y: center.y + waist)

    path.move(to: top)
    path.addQuadCurve(to: right, control: c1)
    path.addQuadCurve(to: bottom, control: c2)
    path.addQuadCurve(to: left, control: c3)
    path.addQuadCurve(to: top, control: c4)
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)

    // 1) macOS Big Sur icon grid: keep a transparent margin around the squircle.
    let margin = size * 0.088
    let squircleRect = canvas.insetBy(dx: margin, dy: margin)
    let corner = squircleRect.width * 0.235
    let squircle = CGPath(
        roundedRect: squircleRect,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 2) Deep indigo → violet base gradient.
    let base = gradient(
        [rgb(61, 90, 254), rgb(124, 77, 255), rgb(147, 51, 234)],
        [0, 0.55, 1]
    )
    ctx.drawLinearGradient(
        base,
        start: CGPoint(x: squircleRect.minX, y: squircleRect.maxY),
        end: CGPoint(x: squircleRect.maxX, y: squircleRect.minY),
        options: []
    )

    // 3) Soft specular highlight near the top-left.
    let highlightCenter = CGPoint(
        x: squircleRect.minX + squircleRect.width * 0.28,
        y: squircleRect.maxY - squircleRect.height * 0.20
    )
    let highlight = gradient(
        [rgb(255, 255, 255, 0.34), rgb(255, 255, 255, 0)],
        [0, 1]
    )
    ctx.drawRadialGradient(
        highlight,
        startCenter: highlightCenter,
        startRadius: 0,
        endCenter: highlightCenter,
        endRadius: squircleRect.width * 0.82,
        options: []
    )

    // 4) Subtle bottom vignette for depth.
    let vignetteCenter = CGPoint(x: squircleRect.midX, y: squircleRect.minY)
    let vignette = gradient(
        [rgb(24, 18, 64, 0.30), rgb(24, 18, 64, 0)],
        [0, 1]
    )
    ctx.drawRadialGradient(
        vignette,
        startCenter: vignetteCenter,
        startRadius: 0,
        endCenter: vignetteCenter,
        endRadius: squircleRect.width * 0.95,
        options: []
    )
    ctx.restoreGState()

    // 5) Hairline inner border.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.12))
    ctx.setLineWidth(size * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    // 6) Chat bubble with tail, with a soft drop shadow.
    let bubbleWidth = squircleRect.width * 0.58
    let bubbleHeight = squircleRect.height * 0.44
    let bubbleRect = CGRect(
        x: squircleRect.midX - bubbleWidth / 2,
        y: squircleRect.midY - bubbleHeight * 0.50,
        width: bubbleWidth,
        height: bubbleHeight
    )
    let bubbleCorner = bubbleHeight * 0.30
    let bubble = CGMutablePath()
    bubble.addRoundedRect(
        in: bubbleRect,
        cornerWidth: bubbleCorner,
        cornerHeight: bubbleCorner
    )
    let tailTop = CGPoint(x: bubbleRect.minX + bubbleWidth * 0.20, y: bubbleRect.minY + bubbleCorner * 0.25)
    let tailTip = CGPoint(x: bubbleRect.minX + bubbleWidth * 0.06, y: bubbleRect.minY - bubbleHeight * 0.20)
    let tailBottom = CGPoint(x: bubbleRect.minX + bubbleWidth * 0.34, y: bubbleRect.minY)
    bubble.move(to: tailTop)
    bubble.addLine(to: tailTip)
    bubble.addLine(to: tailBottom)
    bubble.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.018),
        blur: size * 0.055,
        color: rgb(10, 8, 40, 0.32)
    )
    ctx.addPath(bubble)
    ctx.clip()
    let bubbleFill = gradient(
        [rgb(255, 255, 255), rgb(235, 240, 255)],
        [0, 1]
    )
    ctx.drawLinearGradient(
        bubbleFill,
        start: CGPoint(x: bubbleRect.midX, y: bubbleRect.maxY),
        end: CGPoint(x: bubbleRect.midX, y: bubbleRect.minY),
        options: []
    )
    ctx.restoreGState()

    // 7) AI sparkle inside the bubble.
    let sparkleCenter = CGPoint(x: bubbleRect.midX, y: bubbleRect.midY + bubbleHeight * 0.03)
    let sparkleRadius = bubbleHeight * 0.30
    let sparkle = sparklePath(
        center: sparkleCenter,
        radius: sparkleRadius,
        waist: sparkleRadius * 0.22
    )
    ctx.saveGState()
    ctx.addPath(sparkle)
    ctx.clip()
    let sparkleFill = gradient(
        [rgb(61, 90, 254), rgb(147, 51, 234)],
        [0, 1]
    )
    ctx.drawLinearGradient(
        sparkleFill,
        start: CGPoint(x: sparkleCenter.x - sparkleRadius, y: sparkleCenter.y + sparkleRadius),
        end: CGPoint(x: sparkleCenter.x + sparkleRadius, y: sparkleCenter.y - sparkleRadius),
        options: []
    )
    ctx.restoreGState()

    // 8) Warm clay accent dot — ties the icon to the Claude/terracotta theme.
    let dotRadius = bubbleHeight * 0.085
    let dotCenter = CGPoint(
        x: bubbleRect.maxX - bubbleWidth * 0.15,
        y: bubbleRect.minY + bubbleHeight * 0.20
    )
    ctx.setFillColor(rgb(224, 138, 91))
    ctx.fillEllipse(in: CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))

    image.unlockFocus()
    return image
}

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
