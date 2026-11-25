import CoreImage
import RabbitControlCore
import SwiftUI

/// 远端视频帧渲染:定时从 core 帧槽取 CVPixelBuffer,经 CoreImage 转为 CGImage 显示。
///
/// v1 采用 CIImage→CGImage 路径(GPU 色彩转换,CPU 拷贝一份);后续可换
/// CVMetalTextureCache 零拷贝。帧所有权:take 即转移,渲染完成后必须 release。
final class VideoFrameRenderer {
    private let ciContext = CIContext()
    private var lastSeq: UInt64 = 0

    /// 尝试取新帧并渲染为 CGImage;无新帧返回 nil。调用线程不限。
    func renderLatest() -> CGImage? {
        guard let rawPtr = rc_apple_media_frame_take() else { return nil }
        defer { rc_string_free(rawPtr) }
        let json = String(cString: rawPtr)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ptr = obj["ptr"] as? UInt64, ptr != 0,
              let width = obj["width"] as? Int,
              let height = obj["height"] as? Int,
              let seq = obj["seq"] as? UInt64 else { return nil }
        guard seq != lastSeq else {
            rc_apple_media_frame_release(ptr)
            return nil
        }
        lastSeq = seq
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(
            UnsafeRawPointer(bitPattern: UInt(ptr))!
        ).takeUnretainedValue()
        defer { rc_apple_media_frame_release(ptr) }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(
            image,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }
}

/// 远端画面视图:CADisplayLink 驱动取帧,手势转为归一化输入事件。
struct RemoteVideoView: View {
    var session: SessionService
    var onTapBackground: (() -> Void)?

    @State private var frame: CGImage?
    @State private var renderer = VideoFrameRenderer()
    /// 触控按下期间持续上报移动(模拟鼠标拖拽)。
    @State private var touchActive = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RCColor.stageBg
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text(session.state.displayText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geo.size))
            .onTapGesture {
                // 单击=鼠标左键点按
                session.sendMouseButton(button: "left", pressed: true)
                session.sendMouseButton(button: "left", pressed: false)
                onTapBackground?()
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            if let newFrame = renderer.renderLatest() {
                frame = newFrame
            }
        }
    }

    /// 拖拽:起点按下左键,移动上报归一化坐标,抬起释放。
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !touchActive {
                    touchActive = true
                    session.sendMouseButton(button: "left", pressed: true)
                }
                let nx = value.location.x / max(size.width, 1)
                let ny = value.location.y / max(size.height, 1)
                session.sendMouseMove(nx: nx, ny: ny)
            }
            .onEnded { _ in
                touchActive = false
                session.sendMouseButton(button: "left", pressed: false)
            }
    }
}
