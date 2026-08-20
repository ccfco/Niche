#!/usr/bin/env bash
# Niche 一键部署:生成工程 → Release 构建 → 装入 /Applications → 重启。
# 用法:./scripts/deploy.sh [--debug] [--no-launch]
#   --debug      用 Debug 配置(默认 Release)
#   --no-launch  装好后不自动启动
set -euo pipefail

CONFIG="Release"
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="Debug" ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "未知参数:$arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Niche"
DERIVED="$ROOT/build/deploy"           # 固定产物目录,免去解析默认 DerivedData
DEST="/Applications/${APP_NAME}.app"

echo "▸ [1/6] 生成 Xcode 工程(XcodeGen)…"
xcodegen generate >/dev/null

echo "▸ [2/6] 构建 ${APP_NAME}(${CONFIG}, arm64)…"
xcodebuild \
  -scheme "$APP_NAME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  build >/dev/null

BUILT="$DERIVED/Build/Products/${CONFIG}/${APP_NAME}.app"
[ -d "$BUILT" ] || { echo "✘ 构建产物不存在:$BUILT" >&2; exit 1; }

echo "▸ [3/6] 统一 designated requirement 签名…"
xattr -cr "$BUILT"
REQ="$(mktemp)"
trap 'rm -f "$REQ"' EXIT
echo "designated => identifier \"com.ccfco.Niche\"" | csreq -r- -b "$REQ"
codesign --force --sign - -r "$REQ" "$BUILT"
codesign --verify --strict "$BUILT"
rm -f "$REQ"
trap - EXIT

echo "▸ [4/6] 退出正在运行的 ${APP_NAME}…"
killall -9 "$APP_NAME" 2>/dev/null || true
sleep 1

echo "▸ [5/6] 安装到 ${DEST}…"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

VER="$(/usr/bin/defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
echo "  已安装 ${APP_NAME} ${VER}(${CONFIG})"

if [ "$LAUNCH" -eq 1 ]; then
  echo "▸ [6/6] 启动…"
  open "$DEST"
else
  echo "▸ [6/6] 跳过启动(--no-launch)"
fi

echo "✔ 完成。"
