#!/usr/bin/env bash
# 从 TokenBoom/rabbitcontrol-core GitHub Release 拉取最新预编译 RabbitControlCore.xcframework，
# 校验 SHA-256 完整性后解压至 Vendor/RabbitControlCore.xcframework（不再本地编译 Rust 源码）。
#
# 用法:
#   ./scripts/fetch-core-xcframework.sh [--force] [--sync-headers]
#
# 参数:
#   --force         忽略本地已缓存的同 SHA-256 版本，强制重新下载解压
#   --sync-headers  同时将 xcframework 内的 FFI 头文件同步到 Vendor/include/
#
# 环境变量:
#   RC_CORE_REPO    目标 GitHub 仓库（默认 TokenBoom/rabbitcontrol-core）
#   RC_CORE_TAG     Release 标签（默认 latest，自动取最新正式 Release；也可传如 v0.2.2）
#   GH_TOKEN / GITHUB_TOKEN  可选令牌（公开仓库无需配置，CI 中传入可避免限流）
set -euo pipefail

FORCE=0
SYNC_HEADERS=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --sync-headers) SYNC_HEADERS=1 ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: 未知参数: $arg" >&2
            exit 1
            ;;
    esac
done

IOS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$IOS_REPO/Vendor"
XCF_DIR="$VENDOR_DIR/RabbitControlCore.xcframework"
STAMP_FILE="$XCF_DIR/.release-sha256"

CORE_REPO="${RC_CORE_REPO:-TokenBoom/rabbitcontrol-core}"
CORE_TAG="${RC_CORE_TAG:-latest}"
ARCHIVE_NAME="RabbitControlCore.xcframework.tar.gz"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
META_NAME="platform-ios.json"

if [[ "$CORE_TAG" == "latest" ]]; then
    BASE_URL="https://github.com/${CORE_REPO}/releases/latest/download"
else
    BASE_URL="https://github.com/${CORE_REPO}/releases/download/${CORE_TAG}"
fi

AUTH_ARGS=()
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "$TOKEN" ]]; then
    AUTH_ARGS=(-H "Authorization: Bearer ${TOKEN}")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL --retry 3 ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -o "$TMP_DIR/$CHECKSUM_NAME" "${BASE_URL}/${CHECKSUM_NAME}"
EXPECTED_SHA="$(awk 'NR==1 {print tolower($1)}' "$TMP_DIR/$CHECKSUM_NAME")"
if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: 远端校验文件格式异常: ${BASE_URL}/${CHECKSUM_NAME}" >&2
    exit 1
fi

RELEASE_DESC="$CORE_TAG"
if curl -fsSL --retry 2 ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -o "$TMP_DIR/$META_NAME" "${BASE_URL}/${META_NAME}" 2>/dev/null; then
    PARSED_DESC="$(python3 - "$TMP_DIR/$META_NAME" <<'PY' 2>/dev/null || true
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
core_tag = d.get("coreTag") or ""
media_ver = d.get("version") or ""
if core_tag and media_ver:
    print(f"core {core_tag} / apple-media v{media_ver}")
elif core_tag:
    print(core_tag)
PY
)"
    if [[ -n "$PARSED_DESC" ]]; then
        RELEASE_DESC="$PARSED_DESC"
    fi
fi

sync_include_headers() {
    local hdr_dir="$XCF_DIR/ios-arm64/Headers"
    if [[ -d "$hdr_dir" ]]; then
        mkdir -p "$VENDOR_DIR/include"
        cp "$hdr_dir/rabbitcontrol_core.h" "$VENDOR_DIR/include/rabbitcontrol_core.h"
        if [[ -f "$hdr_dir/RCMetalRenderer.h" ]]; then
            cp "$hdr_dir/RCMetalRenderer.h" "$VENDOR_DIR/include/RCMetalRenderer.h"
        fi
        if [[ -f "$hdr_dir/module.modulemap" ]]; then
            cp "$hdr_dir/module.modulemap" "$VENDOR_DIR/include/module.modulemap"
        fi
    fi
}

if [[ "$FORCE" -eq 0 && -f "$XCF_DIR/Info.plist" && -f "$STAMP_FILE" ]]; then
    LOCAL_SHA="$(tr -d '[:space:]' < "$STAMP_FILE" | tr '[:upper:]' '[:lower:]')"
    if [[ "$LOCAL_SHA" == "$EXPECTED_SHA" ]]; then
        if [[ "$SYNC_HEADERS" -eq 1 ]]; then
            sync_include_headers
        fi
        echo "✓ RabbitControlCore.xcframework 已是最新 Release (${RELEASE_DESC}, sha256=${EXPECTED_SHA:0:12}…)"
        exit 0
    fi
fi

echo "↓ 正在从 ${CORE_REPO} (${RELEASE_DESC}) 下载 ${ARCHIVE_NAME}…"
curl -fsSL --retry 3 ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -o "$TMP_DIR/$ARCHIVE_NAME" "${BASE_URL}/${ARCHIVE_NAME}"
(
    cd "$TMP_DIR"
    shasum -a 256 -c "$CHECKSUM_NAME"
)

mkdir -p "$TMP_DIR/extracted" "$VENDOR_DIR"
tar -xzf "$TMP_DIR/$ARCHIVE_NAME" -C "$TMP_DIR/extracted"
if [[ ! -f "$TMP_DIR/extracted/RabbitControlCore.xcframework/Info.plist" ]]; then
    echo "error: 解压产物缺少 RabbitControlCore.xcframework/Info.plist" >&2
    exit 1
fi

rm -rf "$XCF_DIR"
mv "$TMP_DIR/extracted/RabbitControlCore.xcframework" "$XCF_DIR"
printf '%s\n' "$EXPECTED_SHA" > "$STAMP_FILE"

if [[ "$SYNC_HEADERS" -eq 1 ]]; then
    sync_include_headers
fi

echo "✓ 已就绪 Vendor/RabbitControlCore.xcframework (${RELEASE_DESC}, sha256=${EXPECTED_SHA:0:12}…)"
