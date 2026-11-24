# RabbitControl iOS 常用开发指令

default:
    @just --list

# 生成 RabbitControlIOS.xcodeproj（修改 project.yml 后需要重新生成）
gen:
    xcodegen generate

# 生成工程并用 Xcode 打开
open: gen
    open RabbitControlIOS.xcodeproj

# 打印 xcodebuild 使用的模拟器 destination
dest:
    ./scripts/simulator-destination.sh

# Debug 构建（模拟器）
build: gen
    xcodebuild build -project RabbitControlIOS.xcodeproj -scheme RabbitControlIOS \
        -destination "$(./scripts/simulator-destination.sh)"

# 单元测试与 UI 测试（模拟器）
test: gen
    xcodebuild test -project RabbitControlIOS.xcodeproj -scheme RabbitControlIOS \
        -destination "$(./scripts/simulator-destination.sh)"

# 构建并运行全部测试
verify: build test
    @echo "✓ all checks passed"

# 删除生成的工程
clean:
    rm -rf RabbitControlIOS.xcodeproj
