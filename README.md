# RabbitControl iOS (`TokenBoom/rabbitcontrol-ios`)

RabbitControl iOS 是 macOS 的主控端，不提供 iPhone 整机被控服务。账号设备可通过九位码连接，也支持手动直连。仅观看会话不能发送键鼠或使用远程工具；设备预览来自本次运行收到的画面。UI 回归测试可显式使用 mock 数据。

## 仓库结构

| 路径 | 职责 |
|---|---|
| `project.yml` | 工程定义（[XcodeGen](https://github.com/yonaskolb/XcodeGen)）。`RabbitControlIOS.xcodeproj` 由它生成，不纳入版本控制 |
| `RabbitControlIOS/` | 应用目标。`App/` 为入口与根视图，`Resources/` 为资源与图标 |
| `RabbitControlIOSTests/` | 单元测试（Swift Testing） |
| `RabbitControlIOSUITests/` | UI 测试（XCUITest） |
| `scripts/simulator-destination.sh` | 选取 xcodebuild 使用的 iPhone 模拟器 |
| `scripts/make-app-icon.swift` | 由 macOS 客户端的品牌图标生成 iOS 图标 |
| `justfile` | 常用开发指令 |

## 本地开发

需要 Xcode 26 或更新版本、iOS 模拟器运行时，以及 XcodeGen 2.46 或更新版本。先把与本工作区匹配的 Apple Media xcframework 放入 `Vendor/`；如果两个仓库相邻，也可在 iOS 仓运行 `./scripts/build-core-xcframework.sh` 从源码生成。旧版媒体库不含新的 Metal、剪贴板接口。

```bash
xcodegen generate             # 生成 RabbitControlIOS.xcodeproj
open RabbitControlIOS.xcodeproj
```

源码目录是 Xcode 的同步文件夹：新增源码文件不需要改动 `project.yml`；只有在调整 target、依赖或构建设置之后，才需要修改 `project.yml` 并重新执行 `xcodegen generate`。

装了 [just](https://github.com/casey/just) 的话可以直接用：

| 指令 | 作用 |
|---|---|
| `just open` | 生成工程并用 Xcode 打开 |
| `just build` | Debug 构建 |
| `just test` | 单元测试与 UI 测试 |
| `just verify` | 构建并运行全部测试 |

## 验证

```bash
xcodebuild test \
  -project RabbitControlIOS.xcodeproj \
  -scheme RabbitControlIOS \
  -destination "$(./scripts/simulator-destination.sh)"
```

CI 使用固定版本的 Apple Media release，不会使用本地生成的媒体库。调整媒体接口时，先发布匹配的媒体库，再更新 iOS CI 的 `XCF_TAG`。

账号与工具的集成测试只应使用临时的本机服务、测试账号和隔离模拟器。Mac 测试宿主是 `rc-cli` 的 `ios_accept_local` example，须显式启用 `ios-acceptance` feature；默认不注册真实采集，键鼠、锁屏和剪贴板均使用测试后端。只有检查真实桌面帧时才添加 `--capture-display` 并为该宿主授予 macOS 录屏权限。测试画面不算真实桌面验收。

## 工程配置

| 项 | 值 |
|---|---|
| 部署目标 | iOS 18.0，支持 iPhone 与 iPad |
| Bundle ID | `com.rabbitcontrol.ios` |
| Swift | 6 语言模式，默认 MainActor 隔离（UI 测试目标除外） |
| Info.plist | 由 `project.yml` 生成；仅文稿目录对「文件」App 可见，凭证不在文稿中 |

真机运行之前，需要在 `project.yml` 的 `RabbitControlIOS` target 里填上 `DEVELOPMENT_TEAM`，然后重新生成工程。

## 许可证

AGPL-3.0，与 RabbitControl 的其他仓库一致。
