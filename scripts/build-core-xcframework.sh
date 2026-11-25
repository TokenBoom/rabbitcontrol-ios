#!/usr/bin/env bash
# 构建 rabbitcontrol-core 的移动端 FFI 静态库并打包为 RabbitControlCore.xcframework。
#
# 用法:
#   ./scripts/build-core-xcframework.sh
#
# 环境变量:
#   RC_MEDIA_DIR rabbitcontrol-apple-media 本地检出路径(默认 ../rabbitcontrol-apple-media)。
#                rc-mobile-ffi 与 rc-media-apple 均在该仓,core 以 git tag 钉版为 cargo 依赖。
#   RC_TARGETS   空格分隔的 target 列表,默认覆盖真机与 arm64 模拟器。
#
# 产物:
#   Vendor/RabbitControlCore.xcframework  —— 直接在 project.yml 中链接;
#   各切片的头文件与 modulemap 来自 Apple Media 仓的 include/。
set -euo pipefail

IOS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
MEDIA_DIR="${RC_MEDIA_DIR:-$IOS_REPO/../rabbitcontrol-apple-media}"
if [[ ! -x "$MEDIA_DIR/scripts/build-xcframework.sh" ]]; then
    echo "error: 缺少 rabbitcontrol-apple-media 构建脚本: $MEDIA_DIR" >&2
    exit 1
fi
exec "$MEDIA_DIR/scripts/build-xcframework.sh" "$IOS_REPO/Vendor"
