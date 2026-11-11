// 把彩色图标里白色的「W」抠出来，做成菜单栏用的模板图（黑色 + 透明度）。
// 只用系统自带的 CoreGraphics / ImageIO。由 make-icons.sh 调用：
//   swift template-icon.swift 输入.png 输出.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("用法：template-icon.swift 输入.png 输出.png\n".utf8))
    exit(2)
}

let w = image.width, h = image.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: space, bitmapInfo: info)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// 底色是绿的（最小通道 ≤ 0x43），字是白的（255）。按最小通道算出「有多白」当作透明度。
let low = 80.0
for i in stride(from: 0, to: px.count, by: 4) {
    let a = Double(px[i + 3])
    var out = 0.0
    if a > 0 {
        let m = Double(min(px[i], px[i + 1], px[i + 2])) * 255 / a
        out = a * min(max((m - low) / (255 - low), 0), 1)
    }
    px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
    px[i + 3] = UInt8(out.rounded())
}

let result: CGImage = px.withUnsafeMutableBytes { buf in
    CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
              bytesPerRow: w * 4, space: space, bitmapInfo: info)!.makeImage()!
}
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, result, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
