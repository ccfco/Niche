#!/usr/bin/env bash
#
# Niche 发布 notes 初稿生成器(参照 Clipin 同名脚本)
# ─────────────────────────────────────────────────────────────
# 以「上一个 tag .. 目标 ref」的 git 区间为唯一真相源,按 commit 类型前缀分类。
# 输出为分类初稿,需人工综合后作为最终 notes。
#
# 用法:
#   ./scripts/release-notes.sh                  # 自动用最新 tag..HEAD(首发则全量)
#   ./scripts/release-notes.sh v0.1.0           # v0.1.0..HEAD
#   ./scripts/release-notes.sh v0.1.0 v0.1.1   # 指定两端
#
set -euo pipefail

cur="${2:-HEAD}"

# 首发(无历史 tag)时取全量 commit
if [ -n "${1:-}" ]; then
    prev="$1"
    range="$prev..$cur"
elif prev="$(git describe --tags --abbrev=0 2>/dev/null)"; then
    range="$prev..$cur"
else
    prev=""
    range="$cur"
fi

if [ -n "$prev" ] && ! git rev-parse -q --verify "$prev" >/dev/null 2>&1; then
    echo "ref 不存在: $prev" >&2; exit 1
fi

total=$(git rev-list --count "$range")
repo_slug=$(git remote get-url origin 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')

emit_section() {
    local title="$1"
    local pattern="$2"
    local body
    body=$(git log --no-merges --format='%s' "$range" \
        | grep -E "^($pattern):" \
        | sed -E "s/^($pattern): */- /" || true)
    if [ -n "$body" ]; then
        printf '\n## %s\n\n%s\n' "$title" "$body"
    fi
}

range_label="${prev:+$prev -> }$cur"
echo "# 发布 notes 初稿: $range_label"
echo ""
echo "> 区间 \`$range\` 共 $total 个提交。以下按类型摊开,需人工综合后再作为最终 notes。"

emit_section "新功能(feat)" "feat"
emit_section "修复(fix)" "fix"
emit_section "改进与工程(refactor/perf/test/style/build/ci)" "refactor|perf|test|style|build|ci"

noise=$(git log --no-merges --format='%s' "$range" \
    | grep -E "^(chore|docs|debug):" \
    | wc -l \
    | tr -d ' ')

echo ""
echo "## 未计入正文的噪音提交: $noise (chore/docs/debug)"

if [ -n "$repo_slug" ] && [ -n "$prev" ]; then
    echo ""
    echo "## Compare"
    echo ""
    echo "[$prev...$cur](https://github.com/$repo_slug/compare/$prev...$cur)"
fi
