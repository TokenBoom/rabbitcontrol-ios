#!/usr/bin/env bash
# 构建 rabbitcontrol-core 的移动端 FFI 静态库并打包为 RabbitControlCore.xcframework。
#
# 用法:
#   ./scripts/build-core-xcframework.sh
#
# 环境变量:
#   RC_CORE_DIR  rabbitcontrol-core 本地检出路径(默认 ../rabbitcontrol-core,
#                即与本仓库并列的克隆)。该检出必须包含 crates/rc-mobile-ffi。
#   RC_TARGETS   空格分隔的 target 列表,默认覆盖真机与 arm64 模拟器。
#
# 产物:
#   Vendor/RabbitControlCore.xcframework  —— 直接在 project.yml 中链接;
#   头文件与 modulemap 在 Vendor/include/,会被复制进 xcframework 各切片。
set -euo pipefail

IOS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="${RC_CORE_DIR:-$IOS_REPO/../rabbitcontrol-core}"
TARGETS="${RC_TARGETS:-aarch64-apple-ios aarch64-apple-ios-sim}"
OUT_DIR="$IOS_REPO/Vendor"
XCFW_DIR="$OUT_DIR/RabbitControlCore.xcframework"
CRATE=rc-mobile-ffi

if [[ ! -f "$CORE_DIR/crates/rc-mobile-ffi/Cargo.toml" ]]; then
    echo "error: $CORE_DIR 不是包含 crates/rc-mobile-ffi 的 rabbitcontrol-core 检出" >&2
    echo "       克隆 rabbitcontrol-core 到与本仓库并列的目录,或设置 RC_CORE_DIR" >&2
    exit 1
fi

# rustup 经 Homebrew 安装时 cargo/rustc 不在 PATH,补上 toolchain bin
if ! command -v cargo >/dev/null 2>&1; then
    # uname 报 arm64,rustup toolchain 目录用 aarch64
    arch="$(uname -m)"
    [[ "$arch" == "arm64" ]] && arch="aarch64"
    TC="$HOME/.rustup/toolchains/stable-$arch-apple-darwin/bin"
    if [[ -x "$TC/cargo" ]]; then
        export PATH="$TC:$PATH"
    fi
fi

echo "==> core 检出: $CORE_DIR"

libs=()
for target in $TARGETS; do
    echo "==> cargo build --release -p $CRATE --target $target"
    (cd "$CORE_DIR" && cargo build --release -p "$CRATE" --target "$target")
    libs+=("$CORE_DIR/target/$target/release/lib${CRATE//-/_}.a")
done

rm -rf "$XCFW_DIR"

args=()
for lib in "${libs[@]}"; do
    # 每个切片需要自己的 headers 副本(xcodebuild 要求)
    slice_id="$(basename "$(dirname "$(dirname "$lib")")")"
    hdr_dir="$(mktemp -d)/headers-$slice_id"
    mkdir -p "$hdr_dir"
    cp "$OUT_DIR/include/rabbitcontrol_core.h" "$OUT_DIR/include/module.modulemap" "$hdr_dir/"
    args+=(-library "$lib" -headers "$hdr_dir")
done

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework "${args[@]}" -output "$XCFW_DIR"

echo "==> 完成: $XCFW_DIR"
ls "$XCFW_DIR"
