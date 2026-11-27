# RabbitControl iOS (`TokenBoom/rabbitcontrol-ios`)

RabbitControl iOS 是 macOS 的主控端，不提供 iPhone 整机被控服务。账号设备可通过九位码连接，也支持手动直连。仅观看会话不能发送键鼠或使用远程工具；设备预览来自本次运行收到的画面。UI 回归测试可显式使用 mock 数据。

## 仓库结构

| 路径 | 职责 |
|---|---|
| `project.yml` | 工程定义（[XcodeGen](https://github.com/yonaskolb/XcodeGen)）。`RabbitControlIOS.xcodeproj` 由它生成，不纳入版本控制 |
| `RabbitControlIOS/` | 应用目标。`App/` 为入口与根视图，`Resources/` 为资源与图标 |
| `RabbitControlIOSTests/` | 单元测试（Swift Testing） |
| `RabbitControlIOSUITests/` | UI 测试（XCUITest） |
| `scripts/fetch-core-xcframework.sh` | 从 `TokenBoom/rabbitcontrol-core` 最新 Release 下载并校验预编译 `RabbitControlCore.xcframework` |
| `scripts/verify-spec-lock.py` | 离线校验 `spec-lock.json` 与同步错误目录模型完整性 |
| `scripts/simulator-destination.sh` | 选取 xcodebuild 使用的 iPhone 模拟器 |
| `scripts/make-app-icon.swift` | 由 macOS 客户端的品牌图标生成 iOS 图标 |
| `justfile` | 常用开发指令 |

## 本地开发

需要 Xcode 26 或更新版本、iOS 模拟器运行时，以及 XcodeGen 2.46 或更新版本。本地无需配置 Rust 工具链或自行编译内核，直接从 `TokenBoom/rabbitcontrol-core` Release 拉取最新预编译 `xcframework` 即可：

```bash
./scripts/fetch-core-xcframework.sh   # 自动拉取最新 Release 预编译 xcframework 并校验 SHA-256
xcodegen generate                     # 生成 RabbitControlIOS.xcodeproj
open RabbitControlIOS.xcodeproj
```

源码目录是 Xcode 的同步文件夹：新增源码文件不需要改动 `project.yml`；只有在调整 target、依赖或构建设置之后，才需要修改 `project.yml` 并重新执行 `xcodegen generate`。

装了 [just](https://github.com/casey/just) 的话可以直接用：

| 指令 | 作用 |
|---|---|
| `just fetch-core` | 拉取最新 Release 预编译 xcframework（有缓存时自动跳过） |
| `just sync-core` | 强制重新拉取最新 Release 并同步 `Vendor/include/` 头文件 |
| `just open` | 拉取内核、生成工程并用 Xcode 打开 |
| `just build` | Debug 构建 |
| `just test` | 单元测试与 UI 测试 |
| `just verify` | 校验 spec-lock、构建并运行全部测试 |

## 验证

```bash
xcodebuild test \
  -project RabbitControlIOS.xcodeproj \
  -scheme RabbitControlIOS \
  -destination "$(./scripts/simulator-destination.sh)"
```

CI 与本地开发统一通过 `./scripts/fetch-core-xcframework.sh` 直接拉取 `TokenBoom/rabbitcontrol-core` 最新 Release 预编译产物并执行 SHA-256 校验，不再本地编译媒体或内核静态库。

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
