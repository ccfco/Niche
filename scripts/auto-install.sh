#!/usr/bin/env bash
# Stop hook 用:源码比已装的 /Applications/Niche.app 新时,后台 Release 构建并重装(不自动启动)。
# 源码无变化则跳过,避免纯问答轮次空跑构建。由 .claude/settings.local.json 的 Stop hook 调用。
# 手动也可直接跑:./scripts/auto-install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/Niche.app"
LOG="$ROOT/build/auto-install.log"
mkdir -p "$ROOT/build"

# 是否需要重装:bundle 不存在 → 必装;存在 → 仅当 Sources/**/*.swift 或 project.yml
# 有任一文件比已装 app 新(find -newer 比对 bundle 目录 mtime)。deploy 后 cp 会刷新
# bundle mtime,故下次源码无改动即跳过。
need_install() {
  [ -d "$APP" ] || return 0
  [ -n "$(find "$ROOT/Sources" "$ROOT/project.yml" -type f -newer "$APP" 2>/dev/null | head -1)" ]
}

if need_install; then
  {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') auto-install:构建+装+打开 ==="
    "$ROOT/scripts/deploy.sh"          # 默认 LAUNCH=1:杀旧实例 → 装 → open 到前台
    echo "=== 完成 ==="
  } >>"$LOG" 2>&1
else
  # 源码无变化:不重建,但仍把已装版本带到前台(保证"最新的已经打开")。
  echo "$(date '+%Y-%m-%d %H:%M:%S') 源码无变化,直接打开已装版本。" >>"$LOG"
  open "$APP"
fi
