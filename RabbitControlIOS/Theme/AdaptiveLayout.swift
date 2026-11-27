import SwiftUI

/// 跨设备响应式布局计算规则（纯函数、无全局状态，便于单元测试覆盖所有尺寸断点）。
///
/// 布局结构一律由 Size Class 与实时容器视口几何尺寸共同决定，不硬编码 `UIDevice` 型号，
/// 确保 iPad 全屏、2/3 分屏、台前调度以及 1/3 侧拉窄窗均可平滑切换。
nonisolated enum RCLayout {
    /// 是否启用 iPad 工作台侧边栏框架（`regular` 水平尺寸类）。
    static func usesWorkspaceSplit(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass == .regular
    }

    /// 登录页是否采用左右双栏排布。
    static func prefersTwoColumnLogin(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        viewportSize: CGSize,
        isAccessibilityType: Bool
    ) -> Bool {
        guard !isAccessibilityType else { return false }
        if verticalSizeClass == .compact { return true }
        return horizontalSizeClass == .regular && viewportSize.width >= 680
    }

    /// 远程协助页是否采用左右双栏工作台排布（基于当前内容区自身可用宽度）。
    static func prefersTwoColumnAssist(
        verticalSizeClass: UserInterfaceSizeClass?,
        containerWidth: CGFloat,
        isAccessibilityType: Bool
    ) -> Bool {
        guard !isAccessibilityType else { return false }
        if verticalSizeClass == .compact { return true }
        return containerWidth >= 720
    }

    /// 远控会话是否启用上下分屏专属触控板（修复 iPad 横屏 `verticalSizeClass == .regular` 误触发问题）。
    static func shouldUseSessionSplitTrackpad(
        portraitLayout: PortraitLayout,
        touchMode: TouchInputMode,
        watchOnly: Bool,
        verticalSizeClass: UserInterfaceSizeClass?,
        viewportSize: CGSize
    ) -> Bool {
        guard verticalSizeClass == .regular, !watchOnly else { return false }
        if viewportSize.width > 0, viewportSize.height > 0, viewportSize.width >= viewportSize.height {
            return false
        }
        switch portraitLayout {
        case .fullscreen: return false
        case .splitTrackpad: return true
        case .auto: return touchMode == .trackpad
        }
    }

    /// 远控会话是否使用右侧并排侧边工具抽屉替代模态半屏 Sheet。
    static func prefersSessionSideInspector(
        horizontalSizeClass: UserInterfaceSizeClass?,
        viewportSize: CGSize
    ) -> Bool {
        horizontalSizeClass == .regular && viewportSize.width >= 720
    }

    /// 会话内悬浮键盘扩展条是否使用紧凑单行胶囊排布。
    static func prefersSingleRowKeyboardBar(
        verticalSizeClass: UserInterfaceSizeClass?,
        availableWidth: CGFloat
    ) -> Bool {
        verticalSizeClass == .compact || availableWidth >= 660
    }
}
