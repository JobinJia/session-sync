#!/usr/bin/env bash
# 手动安装（不走插件市场的那条路）：
#   1. 把两个技能软链进 ~/.claude/skills/
#   2. 在 ~/.claude/settings.json 的 SessionStart 里追加一条钩子（保留已有的，不覆盖）
#   3. 首次生成 ~/.claude/branch-sync/config.json
# 全程幂等，重复跑不会重复添加。--uninstall 可原样撤掉。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_DIR/skills"
SETTINGS="$CLAUDE_DIR/settings.json"
DATA_DIR="$CLAUDE_DIR/branch-sync"
HOOK_CMD="$REPO/skills/branch-sync/scripts/sync.sh --hook"
UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖：$1"; exit 1; }; }
need jq; need git

# ── 卸载 ───────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "1" ]; then
  for s in branch-sync repo-inbox; do
    if [ -L "$SKILLS_DIR/$s" ]; then rm -f "$SKILLS_DIR/$s"; echo "已移除软链 $SKILLS_DIR/$s"; fi
  done
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
    jq '(.hooks.SessionStart // []) |= (map(.hooks |= map(select((.command // "") | test("sync\\.sh --hook") | not)))
                                        | map(select((.hooks | length) > 0)))' "$SETTINGS" > "$SETTINGS.tmp" \
      && mv "$SETTINGS.tmp" "$SETTINGS" && echo "已从 settings.json 摘掉钩子（旧文件已备份）"
  fi
  echo "配置和状态留在 ${DATA_DIR}，没有动。确定不要了自己删。"
  exit 0
fi

# ── 1. 软链技能 ────────────────────────────────────────────────────
mkdir -p "$SKILLS_DIR"
for s in branch-sync repo-inbox; do
  target="$REPO/skills/$s"
  link="$SKILLS_DIR/$s"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    echo "软链已就位：$link"
  elif [ -e "$link" ]; then
    echo "！$link 已存在且不是指向本仓库的软链，没动它。要换的话先自己挪走：mv \"$link\" /tmp/"
  else
    ln -s "$target" "$link" && echo "已软链：$link → $target"
  fi
done
chmod +x "$REPO"/skills/*/scripts/*.sh 2>/dev/null

# ── 2. 钩子 ────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"
SETTINGS_EXISTED=1
[ -f "$SETTINGS" ] || { echo '{}' > "$SETTINGS"; SETTINGS_EXISTED=0; }
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "！$SETTINGS 不是合法 JSON，没敢动。修好再跑一次。"; exit 1
fi
if jq -e --arg c "$HOOK_CMD" '[.hooks.SessionStart[]?.hooks[]?.command] | index($c)' "$SETTINGS" >/dev/null 2>&1; then
  echo "SessionStart 钩子已存在，跳过"
elif jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(test("sync\\.sh --hook"))) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
  echo "！已有一条指向别处的 sync.sh 钩子，没动它。确认后手工改成：$HOOK_CMD"
else
  # 全新机器上 settings.json 是我们刚建的空壳，没必要给它留备份
  [ "$SETTINGS_EXISTED" = "1" ] && cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  jq --arg c "$HOOK_CMD" '.hooks //= {} | .hooks.SessionStart //= []
     | .hooks.SessionStart += [{matcher:"", hooks:[{type:"command", command:$c, timeout:60}]}]' \
     "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS" \
     && echo "已追加 SessionStart 钩子（旧文件已备份），现有的其他钩子没动"
fi

# ── 3. 配置 ────────────────────────────────────────────────────────
mkdir -p "$DATA_DIR/state" "$DATA_DIR/reports"
if [ -f "$DATA_DIR/config.json" ]; then
  echo "配置已存在，没覆盖：$DATA_DIR/config.json"
else
  cp "$REPO/config.example.json" "$DATA_DIR/config.json"
  echo "已生成默认配置：$DATA_DIR/config.json"
fi

echo
echo "装好了。新开一个会话，钩子就会在启动时同步你当前所在的仓库。"
echo "手动触发：/branch-sync   看谁回了你：/repo-inbox"
command -v gh >/dev/null 2>&1 || echo "提醒：/repo-inbox 需要 gh CLI 并且登录过（gh auth login）"
exit 0
