// Gera o master 1024×1024 do ícone do VitalScan (CoreGraphics nativo).
// Conceito: coração verde em gradiente com um traçado de ECG branco atravessando.
// Uso: make_icon <saida.png>
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let c = gctx.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

let margin = S * 0.06
let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius = rect.width * 0.235
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// sombra + card base
c.saveGState(); c.addPath(squircle)
c.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.03, color: col(0,0,0,0.6))
c.setFillColor(col(8,8,8)); c.fillPath(); c.restoreGState()

c.saveGState(); c.addPath(squircle); c.clip()
// fundo near-black
let bg = CGGradient(colorsSpace: space,
    colors: [col(18,20,18), col(3,3,3)] as CFArray, locations: [0,1])!
c.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

func ecg(_ p: CGMutablePath, baseY: CGFloat, amp: CGFloat = 1) {
    p.move(to: CGPoint(x: S*0.12, y: baseY))
    p.addLine(to: CGPoint(x: S*0.34, y: baseY))
    p.addLine(to: CGPoint(x: S*0.40, y: baseY + S*0.05*amp))
    p.addLine(to: CGPoint(x: S*0.455, y: baseY - S*0.09*amp))
    p.addLine(to: CGPoint(x: S*0.52, y: baseY + S*0.20*amp))
    p.addLine(to: CGPoint(x: S*0.575, y: baseY - S*0.13*amp))
    p.addLine(to: CGPoint(x: S*0.63, y: baseY))
    p.addLine(to: CGPoint(x: S*0.88, y: baseY))
}
func heartPath(cx: CGFloat, cy: CGFloat, w: CGFloat) -> CGPath {
    let h = w * 0.9; let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: cy - h*0.42))
    p.addCurve(to: CGPoint(x: cx - w*0.5, y: cy + h*0.18),
               control1: CGPoint(x: cx - w*0.22, y: cy - h*0.14), control2: CGPoint(x: cx - w*0.5, y: cy - h*0.06))
    p.addCurve(to: CGPoint(x: cx, y: cy + h*0.30),
               control1: CGPoint(x: cx - w*0.5, y: cy + h*0.42), control2: CGPoint(x: cx - w*0.18, y: cy + h*0.42))
    p.addCurve(to: CGPoint(x: cx + w*0.5, y: cy + h*0.18),
               control1: CGPoint(x: cx + w*0.18, y: cy + h*0.42), control2: CGPoint(x: cx + w*0.5, y: cy + h*0.42))
    p.addCurve(to: CGPoint(x: cx, y: cy - h*0.42),
               control1: CGPoint(x: cx + w*0.5, y: cy - h*0.06), control2: CGPoint(x: cx + w*0.22, y: cy - h*0.14))
    p.closeSubpath(); return p
}

// coração preenchido (gradiente) com glow
let hp = heartPath(cx: S*0.5, cy: S*0.52, w: S*0.52)
c.saveGState(); c.addPath(hp)
c.setShadow(offset: .zero, blur: S*0.05, color: col(92,240,138,0.55))
c.addPath(hp); c.clip()
let hg = CGGradient(colorsSpace: space,
    colors: [col(120,255,160), col(46,180,96), col(24,110,60)] as CFArray, locations: [0,0.55,1])!
c.drawLinearGradient(hg, start: CGPoint(x: S*0.5, y: S*0.78), end: CGPoint(x: S*0.5, y: S*0.26), options: [])
c.restoreGState()

// pulso escuro recortado + núcleo claro atravessando o coração
let line = CGMutablePath(); ecg(line, baseY: S*0.52, amp: 0.85)
c.saveGState(); c.setLineCap(.round); c.setLineJoin(.round)
c.addPath(line); c.setStrokeColor(col(6,20,12)); c.setLineWidth(S*0.05); c.strokePath()
c.addPath(line); c.setStrokeColor(col(210,255,224)); c.setLineWidth(S*0.018); c.strokePath()
c.restoreGState()

// hairline interno
c.addPath(CGPath(roundedRect: rect.insetBy(dx: S*0.006, dy: S*0.006),
    cornerWidth: radius, cornerHeight: radius, transform: nil))
c.setStrokeColor(col(255,255,255,0.06)); c.setLineWidth(S*0.004); c.strokePath()
c.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok -> \(out)")
