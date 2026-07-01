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

# ── 前置检查(先于任何文件改动,否则版本号写回会自己弄脏工作树挡自己) ──
echo "▸ [1/6] 前置检查…"
if [ -n "$(git status --porcelain)" ]; then
    echo "✘ 有未提交改动,请先 commit" >&2; exit 1
fi

# ── 版本 ────────────────────────────────────────────────────
if [ -n "$VER_ARG" ]; then
    VER="$VER_ARG"
    # 写回 project.yml(MARKETING_VERSION)并单独提交,否则这次改动永远不进 tag 指向的 commit
    sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VER\"/" project.yml
    git add project.yml
    git commit -m "chore: 版本号 bump 到 $VER"
    echo "▸ 版本号更新为 $VER(已写回 project.yml 并提交)"
else
    VER="$(grep 'MARKETING_VERSION' project.yml | head -1 \
        | sed -E 's/.*MARKETING_VERSION: *"([^"]+)".*/\1/')"
fi
TAG="v$VER"

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

# ── appcast EdDSA 签名 ───────────────────────────────────────
echo "▸ [5/7] 生成 appcast（EdDSA 签名）…"
command -v generate_appcast >/dev/null 2>&1 || { echo "✘ 缺少 generate_appcast（Sparkle 工具），请装到 PATH" >&2; exit 1; }
# generate_appcast 不收 --output，固定写 <dir>/appcast.xml；写完 cp 到仓库根供客户端拉取。
# 私钥从本机 Keychain 读（与 Clipin 复用同一对 EdDSA 密钥），首次签名会弹 Keychain 授权。
generate_appcast "$DIST" \
    --download-url-prefix "https://github.com/ccfco/Niche/releases/download/$TAG/"
cp "$DIST/appcast.xml" "$ROOT/appcast.xml"

# ── 发布顺序（原子性红线，同 Clipin）─────────────────────────
# appcast 一旦推到 main，已装客户端立刻拉到它指向的下载 URL；若资产还没上传 → 404，更新链断。
# 顺序必须：tag + push 代码 → 建 release 传 zip → 验证资产可下载 → 最后才 push appcast。
echo "▸ [6/7] 打 tag $TAG 并推送代码…"
git tag "$TAG"
git push origin main
git push origin "$TAG"

echo "▸ [7/7] 创建 GitHub release 并上传资产…"
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

echo "▸ 验证 release 资产可下载（appcast 即将指向的下载 URL）…"
# curl HEAD 对 GitHub Releases 不可靠(不保证与 GET 行为一致,也不保证上传后立即全局可见)。
# 用 gh api 查资产真实状态(state==uploaded 且 size>0),确认后再用 curl HEAD 做一次真实可达性兜底。
ASSET_NAME="${APP_NAME}.app.zip"
DOWNLOAD_URL="https://github.com/ccfco/Niche/releases/download/$TAG/${ASSET_NAME}"
ASSET_OK=""
DELAYS=(5 10 20 30 30 30)
for i in "${!DELAYS[@]}"; do
    STATE="$(gh api "repos/ccfco/Niche/releases/tags/$TAG" \
        --jq ".assets[] | select(.name==\"$ASSET_NAME\") | .state" 2>/dev/null || true)"
    SIZE="$(gh api "repos/ccfco/Niche/releases/tags/$TAG" \
        --jq ".assets[] | select(.name==\"$ASSET_NAME\") | .size" 2>/dev/null || true)"
    if [ "$STATE" = "uploaded" ] && [ -n "$SIZE" ] && [ "$SIZE" -gt 0 ]; then
        ASSET_OK=1; echo "  ✓ 资产已就绪（state=uploaded, size=${SIZE}）"; break
    fi
    echo "  资产未就绪（state=${STATE:-unknown}），${DELAYS[$i]}s 后重试（$((i + 1))/${#DELAYS[@]}）…"
    sleep "${DELAYS[$i]}"
done
if [ -z "$ASSET_OK" ]; then
    echo "✘ release 资产轮询 ${#DELAYS[@]} 次仍未就绪，已中止——不推送 appcast，避免客户端拿到 404。" >&2
    echo "  appcast 仍为发版前状态（客户端无害）。回滚：git push origin :$TAG && git tag -d $TAG && gh release delete $TAG --yes" >&2
    exit 1
fi
if ! curl -fsIL "$DOWNLOAD_URL" >/dev/null 2>&1; then
    echo "✘ gh api 报资产已就绪,但实际 HTTP 请求不可达,已中止——不推送 appcast。" >&2
    echo "  appcast 仍为发版前状态（客户端无害）。回滚：git push origin :$TAG && git tag -d $TAG && gh release delete $TAG --yes" >&2
    exit 1
fi
echo "  ✓ HTTP 可达性确认通过"

echo "▸ 推送 appcast（资产已就位，此刻暴露才安全）…"
git add appcast.xml
git commit -m "chore: 更新 appcast $TAG（资产已确认可下载）"
git push origin main

echo "✔ 已发布 ${APP_NAME} ${TAG}"
echo "   https://github.com/ccfco/Niche/releases/tag/${TAG}"
echo "   appcast.xml 已推送，Sparkle 客户端将自动检测。"
