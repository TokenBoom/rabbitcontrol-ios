import SwiftUI

/// 设备卡片缩略图用的 mock 壁纸:接入真实截屏前,用分层渐变模拟远程桌面壁纸。
struct WallpaperView: View {
    var wallpaper: Device.Wallpaper

    var body: some View {
        switch wallpaper {
        case .sunset:
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: 0xF7B733),
                            Color(hex: 0xE8604C),
                        ]),
                        startPoint: CGPoint(x: size.width / 2, y: 0),
                        endPoint: CGPoint(x: size.width / 2, y: size.height)
                    )
                )
                // 远山
                var ridge = Path()
                ridge.move(to: CGPoint(x: 0, y: size.height * 0.62))
                ridge.addLine(to: CGPoint(x: size.width * 0.3, y: size.height * 0.42))
                ridge.addLine(to: CGPoint(x: size.width * 0.55, y: size.height * 0.58))
                ridge.addLine(to: CGPoint(x: size.width * 0.8, y: size.height * 0.38))
                ridge.addLine(to: CGPoint(x: size.width, y: size.height * 0.55))
                ridge.addLine(to: CGPoint(x: size.width, y: size.height))
                ridge.addLine(to: CGPoint(x: 0, y: size.height))
                ridge.closeSubpath()
                context.fill(ridge, with: .color(Color(hex: 0x3D2C4E, opacity: 0.75)))
                // 太阳
                let sun = CGRect(
                    x: size.width * 0.62, y: size.height * 0.15,
                    width: size.height * 0.2, height: size.height * 0.2
                )
                context.fill(Path(ellipseIn: sun), with: .color(Color(hex: 0xFFF3D6, opacity: 0.9)))
            }
        case .coast:
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: 0x7EC8E3),
                            Color(hex: 0x2E7FA8),
                        ]),
                        startPoint: CGPoint(x: size.width / 2, y: 0),
                        endPoint: CGPoint(x: size.width / 2, y: size.height)
                    )
                )
                // 海面
                var sea = Path()
                sea.move(to: CGPoint(x: 0, y: size.height * 0.5))
                sea.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
                sea.addLine(to: CGPoint(x: size.width, y: size.height))
                sea.addLine(to: CGPoint(x: 0, y: size.height))
                sea.closeSubpath()
                context.fill(sea, with: .color(Color(hex: 0x1F6391, opacity: 0.85)))
                // 礁石
                for (x, w) in [(0.15, 0.14), (0.45, 0.1), (0.72, 0.16)] as [(Double, Double)] {
                    let rock = CGRect(
                        x: size.width * x, y: size.height * 0.52,
                        width: size.width * w, height: size.height * 0.16
                    )
                    context.fill(
                        Path(ellipseIn: rock),
                        with: .color(Color(hex: 0x4A4A52, opacity: 0.9))
                    )
                }
            }
        case .lake:
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(hex: 0xB8C6D9),
                            Color(hex: 0x8FA8C8),
                        ]),
                        startPoint: CGPoint(x: size.width / 2, y: 0),
                        endPoint: CGPoint(x: size.width / 2, y: size.height)
                    )
                )
                // 湖面
                var lake = Path()
                lake.move(to: CGPoint(x: 0, y: size.height * 0.55))
                lake.addLine(to: CGPoint(x: size.width, y: size.height * 0.55))
                lake.addLine(to: CGPoint(x: size.width, y: size.height))
                lake.addLine(to: CGPoint(x: 0, y: size.height))
                lake.closeSubpath()
                context.fill(lake, with: .color(Color(hex: 0x5E7FA3, opacity: 0.8)))
                // 晨阳
                let sun = CGRect(
                    x: size.width * 0.42, y: size.height * 0.3,
                    width: size.height * 0.18, height: size.height * 0.18
                )
                context.fill(Path(ellipseIn: sun), with: .color(Color(hex: 0xFFF8E7, opacity: 0.85)))
            }
        }
    }
}
