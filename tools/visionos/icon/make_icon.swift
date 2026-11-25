// Draws the visionOS app icon's three layers (1024x1024 PNGs; visionOS masks them to a circle and
// separates them in depth): back = dusk sky and sun, middle = city skyline and palm, front = the
// "V" chevron. Original artwork; no game or publisher branding.
//   swift tools/visionos/icon/make_icon.swift OUT_DIR
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                          CGFloat(hex & 255) / 255, a])!
}

func layer(_ name: String, opaque: Bool, _ draw: (CGContext) -> Void) {
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
  draw(ctx)
  let url = URL(fileURLWithPath: out).appendingPathComponent(name)
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

let s = CGFloat(size)

// Back: dusk gradient (deep violet at the top to hot orange at the horizon) and a low sun.
layer("back.png", opaque: true) { c in
  let g = CGGradient(colorsSpace: space, colors: [color(0x1B0B3A), color(0x5A1E6E), color(0xE0485A), color(0xFF9A3C)] as CFArray,
                     locations: [0, 0.45, 0.78, 1])!
  c.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.30), options: [.drawsAfterEndLocation])
  let sun = CGGradient(colorsSpace: space, colors: [color(0xFFE08A), color(0xFFB347, 0.9), color(0xFF7A3C, 0)] as CFArray,
                       locations: [0, 0.55, 1])!
  c.drawRadialGradient(sun, startCenter: CGPoint(x: s * 0.5, y: s * 0.40), startRadius: 0,
                       endCenter: CGPoint(x: s * 0.5, y: s * 0.40), endRadius: s * 0.30, options: [])
  // Sun stripes: gaps cut through the lower half of the disc.
  c.setFillColor(color(0xE0485A, 0.85))
  for (i, y) in [0.36, 0.32, 0.285, 0.255].enumerated() {
    c.fill(CGRect(x: s * 0.30, y: s * CGFloat(y), width: s * 0.40, height: s * (0.012 + 0.006 * CGFloat(i))))
  }
}

// Middle: skyline silhouette along the horizon and a palm on the left.
layer("middle.png", opaque: false) { c in
  c.setFillColor(color(0x140726))
  var x: CGFloat = 0
  let heights: [CGFloat] = [0.30, 0.38, 0.33, 0.47, 0.41, 0.36, 0.55, 0.44, 0.39, 0.50, 0.34, 0.42, 0.31, 0.37]
  let widths: [CGFloat] = [0.07, 0.06, 0.08, 0.05, 0.07, 0.06, 0.05, 0.08, 0.06, 0.07, 0.07, 0.06, 0.08, 0.10]
  for (h, w) in zip(heights, widths) {
    c.fill(CGRect(x: x, y: 0, width: s * w + 1, height: s * h))
    x += s * w
  }
  c.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.24))
  // Palm: a curved trunk and five fronds.
  c.setStrokeColor(color(0x140726)); c.setLineCap(.round)
  c.setLineWidth(s * 0.022)
  c.move(to: CGPoint(x: s * 0.20, y: s * 0.24))
  c.addQuadCurve(to: CGPoint(x: s * 0.27, y: s * 0.66), control: CGPoint(x: s * 0.17, y: s * 0.48))
  c.strokePath()
  let top = CGPoint(x: s * 0.27, y: s * 0.66)
  for (dx, dy, cx, cy) in [(-0.17, -0.06, -0.08, 0.06), (-0.12, 0.05, -0.06, 0.08), (0.03, 0.10, 0.0, 0.10),
                           (0.15, 0.02, 0.08, 0.08), (0.16, -0.09, 0.10, 0.03)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    c.setLineWidth(s * 0.03)
    c.move(to: top)
    c.addQuadCurve(to: CGPoint(x: top.x + s * dx, y: top.y + s * dy), control: CGPoint(x: top.x + s * cx, y: top.y + s * cy))
    c.strokePath()
  }
}

// Front: a bold "V" chevron with a light rim, centred a little above the middle.
layer("front.png", opaque: false) { c in
  let v = CGMutablePath()
  v.move(to: CGPoint(x: s * 0.31, y: s * 0.74))
  v.addLine(to: CGPoint(x: s * 0.42, y: s * 0.74))
  v.addLine(to: CGPoint(x: s * 0.50, y: s * 0.50))
  v.addLine(to: CGPoint(x: s * 0.58, y: s * 0.74))
  v.addLine(to: CGPoint(x: s * 0.69, y: s * 0.74))
  v.addLine(to: CGPoint(x: s * 0.555, y: s * 0.38))
  v.addLine(to: CGPoint(x: s * 0.445, y: s * 0.38))
  v.closeSubpath()
  c.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.55))
  c.addPath(v)
  let g = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xFFE3C2)] as CFArray, locations: [0, 1])!
  c.saveGState(); c.clip()
  c.drawLinearGradient(g, start: CGPoint(x: 0, y: s * 0.74), end: CGPoint(x: 0, y: s * 0.38), options: [])
  c.restoreGState()
  c.setShadow(offset: .zero, blur: 0, color: nil)
  c.addPath(v); c.setStrokeColor(color(0x2A0F45, 0.9)); c.setLineWidth(s * 0.008); c.strokePath()
}
print("icon layers in \(out)")
