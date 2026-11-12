// 生成 macOS 输入法的单色模板图标（黑色 + 透明，系统按菜单栏深浅色自己上色）。
//
//   swift icons/macos/make-icons.swift [输出目录]   # 默认 icons/macos
//
// 出两个矢量 PDF，图形和 icons/hicolor/scalable/apps/wowtype.svg 是同一笔 W：
//   menu.pdf      16×16 pt：实心圆里挖出 W。菜单栏、输入法菜单、系统设置的输入法列表用它。
//   caret@2x.pdf  只有 W 一笔。切换输入法时光标旁边的提示用它（系统画蓝色气泡，W 画成白色）。
// 生成的文件提交在仓库里，build.sh 直接拷，打包时不用再跑这个脚本。
import CoreGraphics
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons/macos"

// wowtype.svg 里的那一笔（128×128，y 朝下）
func wPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 31, y: 50))
    p.addCurve(to: CGPoint(x: 47, y: 86), control1: CGPoint(x: 36, y: 72), control2: CGPoint(x: 40, y: 86))
    p.addCurve(to: CGPoint(x: 64, y: 60), control1: CGPoint(x: 55, y: 86), control2: CGPoint(x: 57, y: 60))
    p.addCurve(to: CGPoint(x: 81, y: 86), control1: CGPoint(x: 71, y: 60), control2: CGPoint(x: 73, y: 86))
    p.addCurve(to: CGPoint(x: 99, y: 40), control1: CGPoint(x: 89, y: 86), control2: CGPoint(x: 94, y: 66))
    return p
}

// 一笔描成轮廓（圆头圆角），换到 PDF 坐标（y 朝上）并缩放、平移
func strokeOutline(width: CGFloat, scale: CGFloat, page: CGSize, offset: CGPoint) -> CGPath {
    let outline = wPath().copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    var t = CGAffineTransform(translationX: offset.x, y: page.height - offset.y).scaledBy(x: scale, y: -scale)
    return outline.copy(using: &t)!
}

func writePDF(_ name: String, page: CGSize, path: CGPath) {
    let url = URL(fileURLWithPath: out).appendingPathComponent(name) as CFURL
    var box = CGRect(origin: .zero, size: page)
    let info = [kCGPDFContextCreator as String: "WowType icons/macos/make-icons.swift"] as CFDictionary
    guard let ctx = CGContext(url, mediaBox: &box, info) else { fatalError("写不了 \(name)") }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.endPDFPage()
    ctx.closePDF()
    print("\(out)/\(name)")
}

// 菜单栏：16 pt 的圆，直径 15（和 SVG 里 r=60/128 一样），W 笔画比 SVG 稍粗，16 pt 下看得清
let menuPage = CGSize(width: 16, height: 16)
let menuScale = menuPage.width / 128
let disc = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 15, height: 15), transform: nil)
let menuW = strokeOutline(width: 14, scale: menuScale, page: menuPage, offset: .zero)
writePDF("menu.pdf", page: menuPage, path: disc.subtracting(menuW))

// 光标旁的提示：照系统自带输入法（AinuIM 的 Ainu@2x.pdf，28×36）的做法只给字形，四周留一点边
let caretPage = CGSize(width: 32, height: 36)
let raw = wPath().copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
let caretScale = (caretPage.width - 4) / raw.width
let glyphHeight = raw.height * caretScale
let caretW = strokeOutline(width: 14, scale: caretScale, page: caretPage,
                           offset: CGPoint(x: 2 - raw.minX * caretScale,
                                           y: (caretPage.height - glyphHeight) / 2 - raw.minY * caretScale))
writePDF("caret@2x.pdf", page: caretPage, path: caretW)
