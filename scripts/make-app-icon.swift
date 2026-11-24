#!/usr/bin/env swift
// 由 macOS 客户端的品牌图标生成 iOS 应用图标：1024×1024、满幅、不含透明通道。
//
// 源图标是四角透明的圆角方形，而 iOS 会自行套用圆角遮罩，直接使用会在四角露出黑边。
// 因此这里先裁剪到不透明区域的边界（放大回 1024），再把残留的透明角压成图标边缘的深色。
//
// 用法：swift scripts/make-app-icon.swift <源 icon.png> <输出 icon-1024.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("用法：swift scripts/make-app-icon.swift <源 icon.png> <输出 icon-1024.png>")
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("无法读取图片：\(sourceURL.path)")
}

let width = image.width
let height = image.height

// premultiplied RGBA；行 0 对应图像的下边缘（CoreGraphics 坐标原点在左下角）。
var bytes = [UInt8](repeating: 0, count: width * height * 4)
let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard decoded else { fail("无法解码图片像素") }

/// 返回未预乘的 RGB（0...1），alpha 过低的像素返回 nil。
func color(x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
    guard x >= 0, x < width, y >= 0, y < height else { return nil }
    let offset = (y * width + x) * 4
    let alpha = CGFloat(bytes[offset + 3])
    guard alpha > 128 else { return nil }
    return (CGFloat(bytes[offset]) / alpha, CGFloat(bytes[offset + 1]) / alpha, CGFloat(bytes[offset + 2]) / alpha)
}

// 不透明像素的外接框。源图在圆角方形外还有一圈低 alpha 的投影光晕，
// 这里只认完全不透明（alpha ≥ 250）的像素，免得把光晕也算进图标本体。
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where bytes[(y * width + x) * 4 + 3] >= 250 {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}
guard maxX >= 0 else { fail("源图标完全透明") }

// 取以该外接框为中心的最大正方形
let edge: Int = max(maxX - minX + 1, maxY - minY + 1)
guard edge <= min(width, height) else { fail("源图标比输出尺寸小得太多，请改用更大的源图") }
let originX: Int = min(max((minX + maxX) / 2 - edge / 2, 0), width - edge)
let originY: Int = min(max((minY + maxY) / 2 - edge / 2, 0), height - edge)

// 四个圆角外的透明区域用边缘颜色填实。iOS 的圆角遮罩与源图基本重合，
// 正常情况下看不到这层填充，取边缘一圈颜色的平均即可。
var samples: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = []
for offset in stride(from: 0, to: edge, by: max(edge / 32, 1)) {
    if let sample = color(x: originX + offset, y: originY + 1) { samples.append(sample) }
    if let sample = color(x: originX + offset, y: originY + edge - 2) { samples.append(sample) }
    if let sample = color(x: originX + 1, y: originY + offset) { samples.append(sample) }
    if let sample = color(x: originX + edge - 2, y: originY + offset) { samples.append(sample) }
}
guard !samples.isEmpty else { fail("无法取样图标边缘颜色") }
let fill = (
    red: samples.map(\.red).reduce(0, +) / CGFloat(samples.count),
    green: samples.map(\.green).reduce(0, +) / CGFloat(samples.count),
    blue: samples.map(\.blue).reduce(0, +) / CGFloat(samples.count)
)

// cropping(to:) 的坐标原点在左上角，需要把 Y 翻转
let cropRect = CGRect(x: originX, y: height - originY - edge, width: edge, height: edge)
let canvas = CGRect(x: 0, y: 0, width: side, height: side)
guard let cropped = image.cropping(to: cropRect),
      let context = CGContext(
          data: nil,
          width: side,
          height: side,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else { fail("无法创建输出画布") }
context.interpolationQuality = .high
context.setFillColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
context.fill(canvas)
context.draw(cropped, in: canvas)
guard let icon = context.makeImage() else { fail("无法生成输出图像") }

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fail("无法创建输出文件：\(outputURL.path)") }
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else { fail("无法写出 PNG：\(outputURL.path)") }

func hex(_ value: CGFloat) -> String {
    String(format: "%02X", Int((value * 255).rounded()))
}
func report(_ label: String, _ color: (red: CGFloat, green: CGFloat, blue: CGFloat)?) {
    guard let color else { return }
    print("\(label): #\(hex(color.red))\(hex(color.green))\(hex(color.blue))")
}
print("已写出 \(outputURL.path)（\(side)×\(side)，裁剪自 \(edge)×\(edge)）")
report("填充色", fill)
report("左上蓝色", color(x: originX + edge / 5, y: originY + edge / 10))
report("右下蓝色", color(x: originX + edge * 4 / 5, y: originY + edge * 9 / 10))
