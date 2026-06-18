#!/usr/bin/env bash
#
# Niche 发布脚本:构建 → 签名 → zip → tag → GitHub release
# ─────────────────────────────────────────────────────────────
# 用法:
#   ./scripts/release.sh                              # 版本号从 project.yml 读,notes 用自动初稿
#   ./scripts/release.sh 0.1.1                         # 覆盖版本号(同步写回 project.yml)
#   ./scripts/release.sh --notes-file notes.md         # 用现成 notes 文件(推荐:先综合好再发)
#   ./scripts/release.sh 0.1.1 --notes-file notes.md   # 两者可组合
#
# 前置:gh CLI 已登录;git remote = ccfco/Niche
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Niche"
BUNDLE_ID="com.ccfco.Niche"
DERIVED="$ROOT/build/release"
DIST="$ROOT/build/dist"

# ── 参数:版本号(可选,位置)+ --notes-file(可选)─────────
VER_ARG=""
NOTES_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file)
            NOTES_FILE="${2:-}"
            [ -n "$NOTES_FILE" ] || { echo "✘ --notes-file 需要一个路径参数" >&2; exit 1; }
            shift 2 ;;
        --notes-file=*)
            NOTES_FILE="${1#*=}"
            [ -n "$NOTES_FILE" ] || { echo "✘ --notes-file 需要一个路径参数" >&2; exit 1; }
            shift ;;
        -*)
            echo "✘ 未知参数:$1" >&2; exit 1 ;;
        *)
            VER_ARG="$1"; shift ;;
    esac
done
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then
    echo "✘ notes 文件不存在:$NOTES_FILE" >&2; exit 1
fi

# ── 版本 ────────────────────────────────────────────────────
if [ -n "$VER_ARG" ]; then
    VER="$VER_ARG"
    # 写回 project.yml(MARKETING_VERSION)
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VER\"/" project.yml
    echo "▸ 版本号更新为 $VER(已写回 project.yml)"
else
    VER="$(grep 'MARKETING_VERSION' project.yml | head -1 \
        | sed -E 's/.*MARKETING_VERSION: *"([^"]+)".*/\1/')"
fi
TAG="v$VER"

# ── 前置检查 ─────────────────────────────────────────────────
echo "▸ [1/6] 前置检查…"
if [ -n "$(git status --porcelain)" ]; then
    echo "✘ 有未提交改动,请先 commit" >&2; exit 1
fi
if git rev-parse -q --verify "$TAG" >/dev/null 2>&1; then
    echo "✘ tag $TAG 已存在,如需重发请先 git tag -d $TAG" >&2; exit 1
fi

# ── 构建 ─────────────────────────────────────────────────────
echo "▸ [2/6] XcodeGen + Release 构建(arm64)…"
xcodegen generate >/dev/null
xcodebuild \
    -scheme "$APP_NAME" -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    build >/dev/null

BUILT="$DERIVED/Build/Products/Release/${APP_NAME}.app"
[ -d "$BUILT" ] || { echo "✘ 构建产物不存在:$BUILT" >&2; exit 1; }

# ── 签名 ─────────────────────────────────────────────────────
# 自定义 designated requirement:TCC 按 bundle ID 匹配,更新二进制后权限不丢
echo "▸ [3/6] Ad-hoc 签名(designated requirement = bundle ID)…"
xattr -cr "$BUILT"
REQ=$(mktemp)
echo "designated => identifier \"$BUNDLE_ID\"" | csreq -r- -b "$REQ"
codesign --force --sign - -r "$REQ" "$BUILT"
rm -f "$REQ"
codesign --verify --strict "$BUILT" && echo "  签名验证通过"

# ── 打包 ─────────────────────────────────────────────────────
echo "▸ [4/6] 打包 zip…"
mkdir -p "$DIST"
ZIP="$DIST/${APP_NAME}.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$BUILT" "$ZIP"
echo "  → $ZIP  ($(du -sh "$ZIP" | cut -f1))"

# ── tag + push ───────────────────────────────────────────────
echo "▸ [5/6] 打 tag $TAG 并推送…"
git tag "$TAG"
git push origin main
git push origin "$TAG"

# ── GitHub release ───────────────────────────────────────────
echo "▸ [6/6] 创建 GitHub release…"
if [ -n "$NOTES_FILE" ]; then
    NOTES="$(cat "$NOTES_FILE")"
    echo "  notes 来源:$NOTES_FILE"
else
    NOTES="$(bash "$ROOT/scripts/release-notes.sh" 2>/dev/null || echo "## $APP_NAME $TAG")"
    echo "  notes 来源:release-notes.sh 自动初稿(含 meta 文字,建议用 --notes-file 传综合稿)"
fi
gh release create "$TAG" "$ZIP" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$(cat <<NOTES
$NOTES

---

> 安装提示:本包为 ad-hoc 签名、未经 Apple 公证。首次打开若被 Gatekeeper 拦截,右键 App 选「打开」,或执行 \`xattr -dr com.apple.quarantine /Applications/Niche.app\`。仅支持 Apple Silicon (arm64)。
NOTES
)"

echo "✔ 已发布 ${APP_NAME} ${TAG}"
echo "   https://github.com/ccfco/Niche/releases/tag/${TAG}"
