#!/usr/bin/env bash
# Render docs/assets/oauth-app-logo.png from the app icon's mark.
#
# Why this is not just the app icon exported: GitHub renders an OAuth App logo by
# dropping the square image, uncropped, into a white circular container at roughly
# 48% of the container's diameter (measured). The macOS icon is a near-white squircle
# with specular highlights and transparent margins — inside that container it reads as
# a hard-edged square floating in a white circle, and the highlights turn to mud at
# avatar size. So this draws a flat, full-bleed disc instead: white ground, black mark,
# transparent corners, nothing that has an edge where GitHub puts one.
#
# The one non-obvious requirement is the white bleed. A PNG whose transparent region
# carries RGB 0,0,0 grows a grey ring exactly at the disc's edge, because GitHub's
# downscale averages RGB *without weighting by alpha* and so mixes opaque white with
# transparent black. Painting the transparent region white makes that average white.
# CoreGraphics cannot express this through a premultiplied context (alpha 0 forces RGB
# 0, and the export un-premultiplies to 0,0,0), which is why the buffer below is
# assembled by hand with straight alpha. The self-check at the end reproduces GitHub's
# downscale and fails if a ring comes back.
#
# Needs no Xcode: unlike build-app.sh this uses only SDK frameworks, no actool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARK="$ROOT/apps/GitPic/AppIcon.icon/Assets/mark.png"
OUT="$ROOT/docs/assets/oauth-app-logo.png"

[[ -f "$MARK" ]] || { echo "error: $MARK missing" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Quoted heredoc: nothing here is expanded by the shell. An unquoted one once ran
# three words of its own comment as a command — see 184d8d8.
cat > "$TMP/logo.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: logo.swift <mark.png> <out.png>\n".utf8))
    exit(2)
}
let markURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

guard let src = CGImageSourceCreateWithURL(markURL as CFURL, nil),
      let mark = CGImageSourceCreateImageAtIndex(src, 0, nil) else { die("cannot read the mark") }

/// The canvas. 1024 because that is the mark's own size, and GitHub only ever scales
/// down — anything smaller would be upscaled at the container's largest rendering.
let S = 1024
/// The glyph's ink width as a fraction of the canvas. 0.68 puts its bounding box's
/// *diagonal* at 88% of the disc, so the front frame's rounded corners keep a visible
/// margin of white and no crop of any shape can clip a stroke.
let inkWidth: CGFloat = 0.68

func newCtx(_ w: Int, _ h: Int, gray: Bool = false) -> CGContext {
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let info = gray ? CGImageAlphaInfo.none.rawValue
                    : CGImageAlphaInfo.premultipliedLast.rawValue
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)
    else { die("cannot make a \(w)x\(h) context") }
    return c
}

// ── Measure the ink, rather than trusting a recorded number ──
// A CGBitmapContext's buffer starts at the image's *top* row, so a top-left y indexes
// straight in. Measured here rather than hard-coded so replacing mark.png is enough:
// a stale bounding box would silently crop or off-centre the glyph.
let W = mark.width, H = mark.height
var alpha = [UInt8](repeating: 0, count: W * H * 4)
alpha.withUnsafeMutableBytes { buf in
    guard let c = CGContext(data: buf.baseAddress, width: W, height: H,
                            bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { die("cannot make the measuring context") }
    c.draw(mark, in: CGRect(x: 0, y: 0, width: W, height: H))
}
var minX = W, minY = H, maxX = -1, maxY = -1
for y in 0..<H {
    for x in 0..<W where alpha[(y * W + x) * 4 + 3] > 8 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else { die("the mark has no opaque pixels") }
// `cropping(to:)` takes image coordinates, top-left origin — the same frame measured in.
let ink = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let aspect = ink.height / ink.width
print("  mark \(W)x\(H), ink \(Int(ink.width))x\(Int(ink.height)) at "
      + "(\(Int(ink.origin.x)),\(Int(ink.origin.y)))")

/// The glyph as white-on-transparent, so drawing it onto black yields coverage.
func whiteGlyph() -> CGImage {
    let c = newCtx(W, H)
    let r = CGRect(x: 0, y: 0, width: W, height: H)
    c.draw(mark, in: r)
    c.setBlendMode(.sourceIn)
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    c.fill(r)
    guard let img = c.makeImage()?.cropping(to: ink) else { die("cannot tint the mark") }
    return img
}

/// An 8-bit coverage mask, row 0 = the image's top row.
func coverage(_ draw: (CGContext) -> Void) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: S * S)
    buf.withUnsafeMutableBytes { b in
        guard let c = CGContext(data: b.baseAddress, width: S, height: S,
                                bitsPerComponent: 8, bytesPerRow: S,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { die("cannot make a coverage context") }
        c.setFillColor(CGColor(gray: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: S, height: S))
        draw(c)
    }
    return buf
}
let discCov = coverage { c in
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fillEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
}
let glyph = whiteGlyph()
let inkCov = coverage { c in
    let w = CGFloat(S) * inkWidth, h = w * aspect
    c.draw(glyph, in: CGRect(x: (CGFloat(S) - w) / 2, y: (CGFloat(S) - h) / 2,
                             width: w, height: h))
}

// ── Assemble straight (non-premultiplied) RGBA ──
// Alpha is the disc; colour is white everywhere the ink is not, transparent corners
// included. That last part is the white bleed the header explains. No row flip: both
// the coverage buffers and CGImage put the top row first.
var rgba = [UInt8](repeating: 0, count: S * S * 4)
for row in 0..<S {
    let base = row * S
    for x in 0..<S {
        let c = UInt8(255 - Int(inkCov[base + x]))
        let i = (base + x) * 4
        rgba[i] = c; rgba[i + 1] = c; rgba[i + 2] = c
        rgba[i + 3] = discCov[base + x]
    }
}
guard let provider = CGDataProvider(data: Data(rgba) as CFData),
      let out = CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: S * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false,
                        intent: .defaultIntent),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { die("cannot encode the logo") }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { die("cannot write \(outURL.path)") }

// ── Self-check: reproduce GitHub's downscale and look for the ring ──
// Read back with NSBitmapImageRep, which keeps straight alpha; a premultiplied read
// would re-multiply the bleed away and the check would pass on a file that rings.
guard let data = try? Data(contentsOf: outURL),
      let rep = NSBitmapImageRep(data: data), let px = rep.bitmapData
else { die("cannot read back \(outURL.path)") }
let bpp = rep.bitsPerPixel / 8
func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let i = y * rep.bytesPerRow + x * bpp
    return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
}
for (name, x, y) in [("top-left", 0, 0), ("top-right", S - 1, 0),
                     ("bottom-left", 0, S - 1), ("bottom-right", S - 1, S - 1)] {
    let p = at(x, y)
    guard p.a == 0, p.r == 255, p.g == 255, p.b == 255 else {
        die("the \(name) corner is rgba \(p.r),\(p.g),\(p.b),\(p.a) — the transparent "
            + "region must be white, or GitHub's downscale will draw a grey ring")
    }
}
// Average RGB and alpha separately, then composite on white: alpha-unaware resampling,
// which is what produced the ring this design exists to avoid.
let N = 60
let step = Double(S) / Double(N)
var ring = [Int: Int]()
for oy in 0..<N {
    for ox in 0..<N {
        var sr = 0, sg = 0, sb = 0, sa = 0, n = 0
        for y in Int(Double(oy) * step)..<Int(Double(oy + 1) * step) {
            for x in Int(Double(ox) * step)..<Int(Double(ox + 1) * step) {
                let p = at(x, y)
                sr += p.r; sg += p.g; sb += p.b; sa += p.a; n += 1
            }
        }
        let a = Double(sa) / Double(n) / 255
        let lum = Double(sr * 299 + sg * 587 + sb * 114) / 1000 / Double(n)
        let onWhite = Int((lum * a + 255 * (1 - a)).rounded())
        let dx = Double(ox) - Double(N - 1) / 2, dy = Double(oy) - Double(N - 1) / 2
        let r = Int((dx * dx + dy * dy).squareRoot().rounded())
        ring[r] = min(ring[r] ?? 255, onWhite)
    }
}
// The glyph stops well inside, so every radius from there to the edge must stay white.
let edge = (Int(Double(N) * inkWidth * (1 + aspect * aspect).squareRoot() / 2) + 2)...(N / 2)
for r in edge where (ring[r] ?? 255) < 250 {
    die("a ring survives at radius \(r)/\(N / 2) (darkest \(ring[r]!)) — the transparent "
        + "region's colour is not matching the disc")
}
print("  self-check: corners bleed white, no ring at radii \(edge.lowerBound)–\(edge.upperBound)")
print("  wrote \(outURL.path)")
SWIFT

echo "==> rendering the OAuth App logo"
swift "$TMP/logo.swift" "$MARK" "$OUT"
