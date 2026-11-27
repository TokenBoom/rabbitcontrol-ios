# RabbitControl iOS 常用开发指令

default:
    @just --list

# 从 TokenBoom/rabbitcontrol-core Release 拉取最新预编译 xcframework（已是最新时自动跳过）
fetch-core:
    ./scripts/fetch-core-xcframework.sh

# 强制重新拉取最新 Release xcframework 并同步 Vendor/include/ 头文件
sync-core:
    ./scripts/fetch-core-xcframework.sh --force --sync-headers

# 生成 RabbitControlIOS.xcodeproj（修改 project.yml 后需要重新生成）
gen:
    xcodegen generate

# 拉取最新内核 Release、生成工程并用 Xcode 打开
open: fetch-core gen
    open RabbitControlIOS.xcodeproj

# 打印 xcodebuild 使用的模拟器 destination
dest:
    ./scripts/simulator-destination.sh

# Debug 构建（模拟器）
build: fetch-core gen
    xcodebuild build -project RabbitControlIOS.xcodeproj -scheme RabbitControlIOS \
        -destination "$(./scripts/simulator-destination.sh)"

# 单元测试与 UI 测试（模拟器）
test: fetch-core gen
    xcodebuild test -project RabbitControlIOS.xcodeproj -scheme RabbitControlIOS \
        -destination "$(./scripts/simulator-destination.sh)"

# 校验 rabbitcontrol-spec 同步锁定文件
spec-check:
    python3 ./scripts/verify-spec-lock.py

# 构建并运行全部测试
verify: spec-check build test
    @echo "✓ all checks passed"

# 构建并安装启动到当前连接的 iPhone 真机（使用临时空 entitlements 绕过尚未获批的 Apple multicast 专项权限）
install team="XLH6BHWSX2": fetch-core gen
    #!/usr/bin/env bash
    set -euo pipefail
    UDID="$(xcrun xctrace list devices 2>&1 | awk -F'[()]' '/^[^=].*iPhone/ && !/Simulator/ {print $(NF-1); exit}')"
    CORE_ID="$(xcrun devicectl list devices | awk '/available \(paired\)/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')"
    if [[ -z "$UDID" || -z "$CORE_ID" ]]; then
        echo "error: 未检测到已连接并配对的 iPhone 真机" >&2
        exit 1
    fi
    TMP_ENT="$(mktemp -t rc-empty-ent).plist"
    trap 'rm -f "$TMP_ENT"' EXIT
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict/></plist>' > "$TMP_ENT"
    xcodebuild build \
        -project RabbitControlIOS.xcodeproj \
        -scheme RabbitControlIOS \
        -configuration Debug \
        -destination "platform=iOS,id=${UDID}" \
        -derivedDataPath DerivedData \
        DEVELOPMENT_TEAM="{{team}}" \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_ENTITLEMENTS="$TMP_ENT" \
        -allowProvisioningUpdates
    xcrun devicectl device install app --device "$CORE_ID" DerivedData/Build/Products/Debug-iphoneos/RabbitControlIOS.app
    xcrun devicectl device process launch --device "$CORE_ID" com.rabbitcontrol.ios || echo "✓ 已安装完成（手机当前锁屏，解锁后即可直接打开 RabbitControl）"

# 打包 Release 归档并直接上传至 App Store Connect / TestFlight（自动管理构建号与分发签名）
testflight team="XLH6BHWSX2": fetch-core
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
    TMP_ENT="$(mktemp -t rc-tf-ent).plist"
    TMP_EXP="$(mktemp -t rc-tf-export).plist"
    trap 'rm -f "$TMP_ENT" "$TMP_EXP"' EXIT
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict/></plist>' > "$TMP_ENT"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict><key>method</key><string>app-store-connect</string><key>destination</key><string>upload</string><key>signingStyle</key><string>automatic</string><key>teamID</key><string>{{team}}</string><key>manageAppVersionAndBuildNumber</key><true/></dict></plist>' > "$TMP_EXP"
    rm -rf DerivedData/RabbitControlIOS.xcarchive DerivedData/TestFlightExport
    xcodebuild archive \
        -project RabbitControlIOS.xcodeproj \
        -scheme RabbitControlIOS \
        -configuration Release \
        -destination "generic/platform=iOS" \
        -archivePath DerivedData/RabbitControlIOS.xcarchive \
        DEVELOPMENT_TEAM="{{team}}" \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_ENTITLEMENTS="$TMP_ENT" \
        -allowProvisioningUpdates
    xcodebuild -exportArchive \
        -archivePath DerivedData/RabbitControlIOS.xcarchive \
        -exportOptionsPlist "$TMP_EXP" \
        -exportPath DerivedData/TestFlightExport \
        -allowProvisioningUpdates

# 删除生成的工程
clean:
    rm -rf RabbitControlIOS.xcodeproj
