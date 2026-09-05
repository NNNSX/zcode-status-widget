#!/bin/bash
# 生成 app 图标：CoreGraphics 渲染三灯图标 → iconutil 合成 icns。
# 用法：scripts/gen-icon.sh [输出路径，默认 Resources/icon.icns]
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-Resources/icon.icns}"

SWIFT_BIN="$(command -v swift)" || { echo "swift 不可用（需 Xcode Command Line Tools）"; exit 1; }
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# 渲染脚本：深色圆角底 + 红黄绿三灯（与面板 PanelPalette 同色）。
cat > "$ICONSET/../render.swift" <<'EOF'
import AppKit
import CoreGraphics

let size = Int(CommandLine.arguments[1])!
let path = CommandLine.arguments[2]
let side = CGFloat(size)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 圆角底板（macOS 图标比例 ≈ 22.5% 圆角）。
let radius = side * 0.225
let plate = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
    cornerWidth: radius, cornerHeight: radius, transform: nil
)
ctx.addPath(plate)
ctx.setFillColor(CGColor(red: 25/255, green: 29/255, blue: 35/255, alpha: 1))
ctx.fillPath()
// 细描边提亮边缘。
ctx.addPath(plate)
ctx.setStrokeColor(CGColor(red: 185/255, green: 192/255, blue: 204/255, alpha: 0.18))
ctx.setLineWidth(max(1, side / 128))
ctx.strokePath()

// 三灯：红 #e5484d 黄 #f2c14e 绿 #46b881。
let dot = side * 0.16
let gap = side * 0.30
let cy = side / 2
let xs: [CGFloat] = [side/2 - gap, side/2, side/2 + gap]
let colors: [(CGFloat, CGFloat, CGFloat)] = [
    (229/255, 72/255, 77/255),
    (242/255, 193/255, 78/255),
    (70/255, 184/255, 129/255)
]
for (x, c) in zip(xs, colors) {
    let rect = CGRect(x: x - dot/2, y: cy - dot/2, width: dot, height: dot)
    // 光晕。
    ctx.setShadow(offset: .zero, blur: side * 0.05,
                  color: CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.55))
    ctx.fillEllipse(in: rect)
    ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
    ctx.fillEllipse(in: rect)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
}

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: path))
EOF

for s in 16 32 64 128 256 512; do
  "$SWIFT_BIN" "$ICONSET/../render.swift" "$s" "$ICONSET/icon_${s}x${s}.png"
  "$SWIFT_BIN" "$ICONSET/../render.swift" "$((s * 2))" "$ICONSET/icon_${s}x${s}@2x.png"
done
"$SWIFT_BIN" "$ICONSET/../render.swift" 1024 "$ICONSET/icon_512x512@2x.png"

mkdir -p "$(dirname "$OUTPUT")"
iconutil -c icns -o "$OUTPUT" "$ICONSET"
echo "已生成 $OUTPUT"
