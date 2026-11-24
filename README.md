# RabbitControl iOS (`TokenBoom/rabbitcontrol-ios`)

RabbitControl iOS 客户端，基于 SwiftUI 构建。当前仓库是应用骨架：工程、测试与 CI 已就绪，尚未接入 [`TokenBoom/rabbitcontrol-core`](https://github.com/TokenBoom/rabbitcontrol-core) 的传输与远控能力，根视图仍是占位页面。

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

需要 Xcode 26 或更新版本、iOS 模拟器运行时，以及 XcodeGen 2.46 或更新版本（`brew install xcodegen`）。

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

CI（`.github/workflows/ci.yml`）在 macOS runner 上执行同一套流程：安装 XcodeGen、生成工程、在模拟器上构建并测试。与 Rust 仓库的 `-D warnings` 一致，CI 上编译警告视为错误。

## 工程配置

| 项 | 值 |
|---|---|
| 部署目标 | iOS 18.0，支持 iPhone 与 iPad |
| Bundle ID | `com.rabbitcontrol.ios` |
| Swift | 6 语言模式，默认 MainActor 隔离（UI 测试目标除外） |
| Info.plist | 不单独维护文件，由 `project.yml` 中的 `INFOPLIST_KEY_*` 生成 |

真机运行之前，需要在 `project.yml` 的 `RabbitControlIOS` target 里填上 `DEVELOPMENT_TEAM`，然后重新生成工程。

## 许可证

AGPL-3.0，与 RabbitControl 的其他仓库一致。
