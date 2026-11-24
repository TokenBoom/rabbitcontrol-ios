#!/bin/bash
# 打印 xcodebuild 的 -destination 参数：优先用已启动的 iPhone 模拟器，
# 否则取最新 iOS 运行时下的第一台 iPhone。
#
# 用法：xcodebuild -destination "$(scripts/simulator-destination.sh)" ...
# 兼容 macOS 自带的 bash 3.2（GitHub Actions 的 macOS runner 也是这个版本）。
set -euo pipefail

in_ios_runtime=0
found_in_runtime=0
udid=""
booted_udid=""

while IFS= read -r line; do
    case "$line" in
        "-- iOS "*)
            in_ios_runtime=1
            found_in_runtime=0
            ;;
        --*)
            in_ios_runtime=0
            ;;
        *"iPhone "*)
            if [[ "$line" =~ \(([0-9A-Fa-f-]{36})\) ]]; then
                candidate="${BASH_REMATCH[1]}"
                if [[ "$line" == *"(Booted)"* ]] && [ -z "$booted_udid" ]; then
                    booted_udid="$candidate"
                fi
                if [ "$in_ios_runtime" -eq 1 ] && [ "$found_in_runtime" -eq 0 ]; then
                    udid="$candidate"
                    found_in_runtime=1
                fi
            fi
            ;;
    esac
done < <(xcrun simctl list devices available)

[ -n "$booted_udid" ] && udid="$booted_udid"

if [ -z "$udid" ]; then
    echo "没有可用的 iPhone 模拟器，请先在 Xcode 中下载 iOS 模拟器运行时" >&2
    exit 1
fi

echo "platform=iOS Simulator,id=$udid"
