#!/usr/bin/env bash
# branch-sync: keep the current repo's main branch fresh and merged into the
# working branch. Safe by design: every risky path rolls back to the exact
# state it started from. Shared by the SessionStart hook and the /branch-sync skill.
set -uo pipefail

# BRANCH_SYNC_DIR 可以把配置/状态/报告整体挪走 —— 测试时用它做隔离，
# 免得把真实配置和状态搅进来。日常不用设。
CONFIG_DIR="${BRANCH_SYNC_DIR:-$HOME/.claude/branch-sync}"
# 这个工具早先叫 session-sync、数据目录叫 session-init。老目录还在而新目录还没建，
# 就整体搬过去 —— 不然升级一次等于把"卡了几天""已读到哪"这些累积状态全丢了。
if [ ! -d "$CONFIG_DIR" ] && [ -d "$HOME/.claude/session-init" ] && [ -z "${BRANCH_SYNC_DIR:-}" ]; then
  mv "$HOME/.claude/session-init" "$CONFIG_DIR" 2>/dev/null
fi
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="$CONFIG_DIR/state"
REPORT_DIR="$CONFIG_DIR/reports"
mkdir -p "$STATE_DIR" "$REPORT_DIR"

MODE="cli"          # cli | hook
DRY=0
FORCE=0
REPORT_ONLY=0
ALL=0
TARGET=""
HOOK_SOURCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hook)    MODE="hook" ;;
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --report)  REPORT_ONLY=1 ;;
    --all)     ALL=1 ;;
    --repo)    shift; TARGET="${1:-}" ;;
    --config)  echo "$CONFIG_FILE"; exit 0 ;;
    *)         ;;
  esac
  shift
done

# ---------- config ----------
write_default_config() {
  cat > "$CONFIG_FILE" <<'CFG'
{
  "enabled": true,
  "onSessionStart": {
    "enabled": true,
    "sources": ["startup", "resume"],
    "freshnessMinutes": 15
  },
  "tasks": {
    "updateMain": true,
    "mergeIntoBranch": true,
    "summarize": true
  },
  "blockedEscalateDays": 7,
  "dirtyWorktree": "stash",
  "mergeStrategy": "merge",
  "protectedBranches": ["main", "master", "release/*"],
  "skipBranches": [],
  "workspaceRoot": "",
  "repos": {},
  "inbox": {
    "org": "",
    "includeCI": true,
    "closedLookbackDays": 30
  }
}
CFG
}
[ -f "$CONFIG_FILE" ] || write_default_config
jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || { [ "$MODE" = "cli" ] && echo "config.json 解析失败：$CONFIG_FILE"; exit 0; }

cfg() { jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null; }
cfg_bool() { local v; v=$(jq -r "$1" "$CONFIG_FILE" 2>/dev/null); [ "$v" = "false" ] && echo 0 || echo 1; }
# 配置里的数字一律走这里。直接把配置值丢进 $(( )) 的话，写成 "abc" 会被 bash
# 当变量名，set -u 下整个脚本以 unbound variable 死掉 —— 一个笔误废掉整个工具。
cfg_num() { # $1 = jq 路径, $2 = 兜底值
  local v; v=$(jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) echo "$2" ;; *) echo "$v" ;; esac
}

[ "$(cfg_bool '.enabled')" = "1" ] || exit 0

# ---------- hook payload ----------
if [ "$MODE" = "hook" ]; then
  payload=$(cat 2>/dev/null)
  HOOK_SOURCE=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null)
  hook_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$hook_cwd" ] && [ -z "$TARGET" ] && TARGET="$hook_cwd"
  [ "$(cfg_bool '.onSessionStart.enabled')" = "1" ] || exit 0
  if [ -n "$HOOK_SOURCE" ]; then
    allowed=$(jq -r --arg s "$HOOK_SOURCE" '(.onSessionStart.sources // ["startup","resume"]) | index($s) // empty' "$CONFIG_FILE")
    [ -n "$allowed" ] || exit 0
  fi
fi
[ -n "$TARGET" ] || TARGET="$PWD"

DIRTY_MODE=$(cfg '.dirtyWorktree'); [ -n "$DIRTY_MODE" ] || DIRTY_MODE="stash"
MERGE_STRATEGY=$(cfg '.mergeStrategy'); [ -n "$MERGE_STRATEGY" ] || MERGE_STRATEGY="merge"
FRESH_MIN=$(cfg_num '.onSessionStart.freshnessMinutes' 15)
ESCALATE_DAYS=$(cfg_num '.blockedEscalateDays' 7)
R_ESCALATED=0

# ---------- helpers ----------
GIT_NET=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15)

repo_key() { # $1 = toplevel
  local base hash
  base=$(basename "$1")
  hash=$(printf '%s' "$1" | shasum | cut -c1-6)
  if [ -f "$STATE_DIR/$base.json" ]; then
    local known
    known=$(jq -r '.path // empty' "$STATE_DIR/$base.json" 2>/dev/null)
    if [ -n "$known" ] && [ "$known" != "$1" ]; then echo "$base-$hash"; return; fi
  fi
  echo "$base"
}

# bash 3.2 (macOS default) has no mapfile, so glob lists are streamed from jq.
matches_cfg_glob() { # $1 = value, $2 = jq path to a string array
  local v="$1" path="$2" g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$v" in $g) return 0 ;; esac
  done < <(jq -r "$path" "$CONFIG_FILE" 2>/dev/null)
  return 1
}

resolve_default_branch() { # $1 = toplevel, $2 = repo name, $3 = state file
  local top="$1" name="$2" statef="$3" b cached cached_at now
  b=$(jq -r --arg n "$name" '.repos[$n].defaultBranch // empty' "$CONFIG_FILE" 2>/dev/null)
  [ -n "$b" ] && { echo "config 覆盖|$b"; return; }
  if [ -f "$statef" ]; then
    cached=$(jq -r '.default_branch // empty' "$statef" 2>/dev/null)
    cached_at=$(jq -r '.default_branch_at // 0' "$statef" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$cached" ] && [ $((now - cached_at)) -lt 604800 ]; then echo "state 缓存|$cached"; return; fi
  fi
  b=$(cd "$top" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
  [ -n "$b" ] && { echo "gh 查询|$b"; return; }
  b=$(git -C "$top" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  [ -n "$b" ] && { echo "origin/HEAD|$b"; return; }
  for b in main master; do
    git -C "$top" show-ref --verify --quiet "refs/remotes/origin/$b" && { echo "兜底猜测|$b"; return; }
  done
  echo ""
}

stuck_days() { # $1 = epoch；返回卡了几天
  local since now
  since="${1:-0}"
  case "$since" in ''|*[!0-9]*) echo 0; return ;; esac
  [ "$since" -gt 0 ] || { echo 0; return; }
  now=$(date +%s)
  echo $(( (now - since) / 86400 ))
}

# 未提交改动的文件 ∩ 这次要合进来的改动的文件。
# 有交集就说明 stash 之后再恢复会撞上，属于「合得成但恢复不回来」那一类。
# 必须用 -z：不带 -z 的时候，git 会把含空格或非 ASCII 的路径加引号并做八进制转义
# （`"src/\345\270\246..."`），拿去和 diff 的输出比对永远对不上，撞车就检测不出来，
# 于是「先算后斩」的承诺在这类文件名上直接失效。-z 输出的是原始字节，没有转义。
overlap_files() { # $1=top $2=mb
  local dirty incoming
  dirty=$(git -C "$1" status --porcelain -z 2>/dev/null | tr '\0' '\n' | sed 's/^...//' | grep -v '^$' | sort -u)
  [ -n "$dirty" ] || return 0
  incoming=$(git -C "$1" diff --name-only -z "HEAD..$2" 2>/dev/null | tr '\0' '\n' | grep -v '^$' | sort -u)
  [ -n "$incoming" ] || return 0
  comm -12 <(printf '%s\n' "$dirty") <(printf '%s\n' "$incoming") 2>/dev/null | grep -v '^$' | head -20
}

# ---------- 并发锁 ----------
# 同一个仓可能被两个同时启动的会话各跑一遍：一个在 stash，另一个在 merge，
# 中间还夹着回滚，谁也说不准最后剩下什么。`mkdir` 在 POSIX 上是原子的，拿它当锁。
LOCK_PATH=""
LOCK_STALE_SECONDS=600

release_lock() {
  [ -n "${LOCK_PATH:-}" ] && [ -d "$LOCK_PATH" ] && rm -rf "$LOCK_PATH"
  LOCK_PATH=""
  return 0
}
# 脚本被打断（超时、Ctrl-C）也要把锁还回去，否则这个仓会被自己锁死到过期
trap 'release_lock' EXIT INT TERM

acquire_lock() { # $1 = 锁路径
  local lock="$1" age now mtime
  if mkdir "$lock" 2>/dev/null; then
    echo $$ > "$lock/pid" 2>/dev/null
    LOCK_PATH="$lock"
    return 0
  fi
  # 没抢到：可能是别人正在跑，也可能是上次被 kill -9 留下的死锁
  now=$(date +%s)
  mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
  case "$mtime" in ''|*[!0-9]*) mtime="$now" ;; esac
  age=$(( now - mtime ))
  if [ "$age" -gt "$LOCK_STALE_SECONDS" ]; then
    rm -rf "$lock" 2>/dev/null
    if mkdir "$lock" 2>/dev/null; then
      echo $$ > "$lock/pid" 2>/dev/null
      LOCK_PATH="$lock"
      return 0
    fi
  fi
  return 1
}

# ---------- core ----------
# Sets: R_STATUS R_SUMMARY R_REPORT_PATH
sync_repo() {
  local dir="$1"
  R_STATUS=""; R_SUMMARY=""; R_REPORT_PATH=""; R_CONFLICTS=""; R_MB_SRC="未知"
  R_BLOCKED_KIND=""; R_BLOCKED_HEAD=""; R_BLOCKED_MAIN=""; R_BLOCKED_SINCE=0; R_STUCK_DAYS=0

  local top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$top" ] || { R_STATUS="not-a-repo"; return; }

  local name key statef reportf
  name=$(basename "$top")
  key=$(repo_key "$top")
  statef="$STATE_DIR/$key.json"
  reportf="$REPORT_DIR/$key.md"
  R_REPORT_PATH="$reportf"

  local repo_enabled
  # 注意：不能写 `.enabled // empty` —— jq 的 // 会把 false 当成「不存在」，
  # 于是 "enabled": false 永远关不掉这个仓。同理别用 `// true`。
  repo_enabled=$(jq -r --arg n "$name" 'if (.repos[$n].enabled) == false then "false" else "" end' "$CONFIG_FILE" 2>/dev/null)
  [ "$repo_enabled" = "false" ] && { R_STATUS="skipped-disabled"; return; }

  if [ "$REPORT_ONLY" = "1" ]; then
    R_STATUS="report-only"; return
  fi

  # 只读路径（--report / --dry-run）不需要锁，会动手的才要
  if [ "$DRY" != "1" ]; then
    acquire_lock "$STATE_DIR/$key.lock" || {
      # 另一个会话正在同步这个仓，让它跑完就行，这边安静退出
      R_STATUS="skipped-locked"; return
    }
  fi

  # freshness
  if [ "$FORCE" != "1" ] && [ -f "$statef" ]; then
    local last now
    last=$(jq -r '.last_sync_epoch // 0' "$statef" 2>/dev/null)
    now=$(date +%s)
    if [ "$last" -gt 0 ] 2>/dev/null && [ $((now - last)) -lt $((FRESH_MIN * 60)) ]; then
      R_STATUS="skipped-fresh"; return
    fi
  fi

  git -C "$top" remote get-url origin >/dev/null 2>&1 || { R_STATUS="no-remote"; return; }

  local cur
  cur=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$cur" = "HEAD" ] && { R_STATUS="skipped-detached"; return; }

  local mb mb_raw
  mb_raw=$(resolve_default_branch "$top" "$name" "$statef")
  mb="${mb_raw#*|}"
  [ -n "$mb_raw" ] && R_MB_SRC="${mb_raw%%|*}"
  [ -n "$mb" ] || { R_STATUS="no-default-branch"; return; }

  if matches_cfg_glob "$cur" '.skipBranches[]? // empty'; then
    R_STATUS="skipped-branch"; return
  fi

  if [ "$DRY" = "1" ]; then
    local dirty_now plan
    dirty_now=$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d " ")
    R_STATUS="dry-run"
    plan="fetch origin → 快进本地 $mb"
    if [ "$cur" != "$mb" ]; then
      if matches_cfg_glob "$cur" '.protectedBranches[]? // empty'; then
        plan="$plan → $cur 在保护分支名单里，不合并"
      elif [ "$dirty_now" != "0" ] && [ "$DIRTY_MODE" = "stash" ]; then
        plan="$plan → stash $dirty_now 项改动 → merge $mb 进 $cur → 恢复改动"
      elif [ "$dirty_now" != "0" ]; then
        plan="$plan → 工作区脏且策略为 ${DIRTY_MODE}，不合并"
      else
        plan="$plan → merge $mb 进 $cur"
      fi
    else
      plan="${plan}（当前就在 $mb 上，无需合并）"
    fi
    R_SUMMARY="${name}：当前分支 ${cur}，主分支 ${mb}（来源：${R_MB_SRC}），工作区改动 $dirty_now 项。计划：$plan"
    return
  fi

  # 1) fetch
  local fetch_err
  fetch_err=$(git -C "$top" "${GIT_NET[@]}" fetch --prune origin 2>&1) || {
    R_STATUS="fetch-failed"; R_SUMMARY="fetch 失败：$(printf '%s' "$fetch_err" | tail -2 | tr '\n' ' ')"; return
  }

  # 2) update local default branch (never checks out, so a dirty tree is fine)
  local main_before main_after=""
  main_before=$(git -C "$top" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)
  local main_updated=0
  if [ "$(cfg_bool '.tasks.updateMain')" = "1" ]; then
    if [ "$cur" = "$mb" ]; then
      git -C "$top" merge --ff-only "origin/$mb" >/dev/null 2>&1 || {
        # 快进失败有两种原因，说成同一种就是误诊：真分歧（本地有远端没有的提交），
        # 还是工作区脏、git 不肯覆盖你没提交的改动。后者去查"分歧"只会白费功夫。
        if git -C "$top" merge-base --is-ancestor "$mb" "origin/$mb" 2>/dev/null; then
          R_STATUS="dirty-blocks-ff"
        else
          R_STATUS="main-diverged"
        fi
      }
    else
      git -C "$top" fetch origin "$mb:$mb" >/dev/null 2>&1 || { R_STATUS="main-diverged"; }
    fi
    main_after=$(git -C "$top" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)
    [ "$main_before" != "$main_after" ] && main_updated=1
  else
    main_after="$main_before"
  fi
  if [ "${R_STATUS:-}" = "main-diverged" ] || [ "${R_STATUS:-}" = "dirty-blocks-ff" ]; then
    if [ "${R_STATUS}" = "dirty-blocks-ff" ]; then
      R_SUMMARY="你正停在 ${mb} 上且有未提交改动，git 不肯覆盖它们，所以 ${mb} 没能快进（不是分歧）"
    else
      R_SUMMARY="本地 ${mb} 有远端没有的提交，无法快进，已停手"
    fi
    # 修 7：这条路径没有评估过合并，别把上一次记下的阻塞信息抹掉
    R_BLOCKED_KIND=$(jq -r '.blocked_kind // ""' "$statef" 2>/dev/null)
    R_BLOCKED_HEAD=$(jq -r '.blocked_head // ""' "$statef" 2>/dev/null)
    R_BLOCKED_MAIN=$(jq -r '.blocked_main // ""' "$statef" 2>/dev/null)
    R_BLOCKED_SINCE=$(jq -r '.blocked_since // 0' "$statef" 2>/dev/null)
    R_CONFLICTS=$(jq -r '.blocked_files // ""' "$statef" 2>/dev/null)
    write_state "$statef" "$top" "$mb" "$cur" "" ""
    return
  fi

  # 3) merge default branch into the working branch
  local pre_sha post_sha="" merged=0 stash_sha="" note=""
  pre_sha=$(git -C "$top" rev-parse HEAD)
  post_sha="$pre_sha"
  if [ "$(cfg_bool '.tasks.mergeIntoBranch')" = "1" ] && [ "$cur" != "$mb" ]; then
    if matches_cfg_glob "$cur" '.protectedBranches[]? // empty'; then
      R_STATUS="skipped-protected-branch"
    elif git -C "$top" merge-base --is-ancestor "$mb" HEAD 2>/dev/null; then
      R_STATUS="${R_STATUS:-branch-already-current}"
    else
      # ── 兜底二：同一个已知阻塞不重复空转 ──────────────────────────
      # 上次卡住时两边的提交都没变过，就没有重算的必要，直接沿用上次的结论，
      # 只把「卡了多久」这个数字往上加 —— 冲突拖着不解决只会越来越难解。
      local prev_kind prev_head prev_main prev_since prev_files
      prev_kind=$(jq -r '.blocked_kind // ""' "$statef" 2>/dev/null)
      prev_head=$(jq -r '.blocked_head // ""' "$statef" 2>/dev/null)
      prev_main=$(jq -r '.blocked_main // ""' "$statef" 2>/dev/null)
      prev_since=$(jq -r '.blocked_since // 0' "$statef" 2>/dev/null)
      prev_files=$(jq -r '.blocked_files // ""' "$statef" 2>/dev/null)

      local skip_merge=0
      if [ -n "$prev_kind" ] && [ "$prev_head" = "$pre_sha" ] && [ "$prev_main" = "$main_after" ]; then
        R_STATUS="$prev_kind"
        R_CONFLICTS="$prev_files"
        R_BLOCKED_KIND="$prev_kind"
        R_BLOCKED_HEAD="$pre_sha"
        R_BLOCKED_MAIN="$main_after"
        R_BLOCKED_SINCE="$prev_since"
        R_STUCK_DAYS=$(stuck_days "$prev_since")
        note="还是上次那个阻塞，两边都没动过（已经卡了 ${R_STUCK_DAYS} 天）"
        skip_merge=1
      else
        # ── 兜底一：先算后斩 ────────────────────────────────────────
        # `merge-tree` 在内存里把合并算完，全程不碰工作区、不 stash、不留中间态。
        # 只有算出来确实干净，下面才会真的动手 —— 这样「启动时自动改坏工作区」
        # 这一整类风险在正常路径上压根不会发生，回滚逻辑退居保险丝。
        local mt_out mt_rc
        mt_out=$(git -C "$top" merge-tree --write-tree --name-only HEAD "$mb" 2>/dev/null)
        mt_rc=$?
        if [ "$mt_rc" != "0" ]; then
          # merge-tree 的输出是：第一行 tree oid，接着冲突文件清单，空行之后才是
          # 「Auto-merging …」这类说明文字。只要清单那一段，遇到空行就停。
          R_CONFLICTS=$(printf '%s\n' "$mt_out" | tail -n +2 | sed '/^$/q' | grep -v '^$' | head -20)
          R_STATUS="merge-conflict"
          R_BLOCKED_KIND="merge-conflict"
          note="预演算出会冲突，所以一步都没动手（工作区、HEAD、stash 全没碰过）"
          skip_merge=1
        fi
      fi

      local dirty="" stash_ref=""
      if [ "$skip_merge" = "0" ]; then
      dirty=$(git -C "$top" status --porcelain 2>/dev/null)
      if [ -n "$dirty" ]; then
        case "$DIRTY_MODE" in
          skip)     R_STATUS="skipped-dirty"; note="工作区有未提交改动，按配置跳过" ;;
          mainOnly) R_STATUS="dirty-main-only"; note="工作区有未提交改动，只更新了 ${mb}，未合并" ;;
          *)
            # 兜底一之二：merge-tree 只看得见已提交的东西，看不见你手上没提交的改动。
            # 所以再比一次：你改的文件和这次要合进来的文件有没有交集。有交集 =
            # 合得成但 stash 恢复不回来，那就干脆别动手。
            local overlap
            overlap=$(overlap_files "$top" "$mb")
            if [ -n "$overlap" ]; then
              R_STATUS="dirty-overlap"
              R_BLOCKED_KIND="dirty-overlap"
              R_CONFLICTS="$overlap"
              note="你没提交的改动正好落在这次要合进来的文件上，恢复时会撞车，所以没动手（工作区没被碰过）"
              skip_merge=1
            fi
            if [ "$skip_merge" = "0" ]; then
            local msg="branch-sync-auto-$(date +%Y%m%d-%H%M%S)"
            if git -C "$top" stash push -u -m "$msg" >/dev/null 2>&1; then
              stash_ref=$(git -C "$top" stash list --format='%gd %gs' 2>/dev/null | grep -F "$msg" | head -1 | awk '{print $1}')
              [ -n "$stash_ref" ] && stash_sha=$(git -C "$top" rev-parse "$stash_ref" 2>/dev/null)
            else
              R_STATUS="stash-failed"; note="stash 失败，未做合并"
            fi
            fi
            ;;
        esac
      fi
      fi

      if [ "$skip_merge" = "0" ] && { [ -z "${R_STATUS:-}" ] || [ "$R_STATUS" = "branch-already-current" ]; }; then
        local merge_ok=1
        if [ "$MERGE_STRATEGY" = "rebase" ]; then
          git -C "$top" rebase "$mb" >/dev/null 2>&1 || {
            merge_ok=0
            R_CONFLICTS=$(git -C "$top" diff --name-only --diff-filter=U 2>/dev/null | head -20)
            git -C "$top" rebase --abort >/dev/null 2>&1
          }
        else
          git -C "$top" merge --no-edit "$mb" >/dev/null 2>&1 || {
            merge_ok=0
            R_CONFLICTS=$(git -C "$top" diff --name-only --diff-filter=U 2>/dev/null | head -20)
            git -C "$top" merge --abort >/dev/null 2>&1
          }
        fi

        if [ "$merge_ok" = "1" ]; then
          post_sha=$(git -C "$top" rev-parse HEAD)
          merged=1
          R_STATUS="ok"
          if [ -n "$stash_ref" ]; then
            # re-resolve: the ref index can shift, match by sha
            local ref2
            ref2=$(git -C "$top" stash list --format='%gd %H' 2>/dev/null | grep -F "$stash_sha" | head -1 | awk '{print $1}')
            [ -n "$ref2" ] || ref2="$stash_ref"
            if git -C "$top" stash pop "$ref2" >/dev/null 2>&1; then
              note="有未提交改动，已 stash → 合并 → 恢复，工作区原样"
              R_STATUS="dirty-stashed"
            else
              # all-or-nothing rollback: undo the merge, restore the stash cleanly
              R_CONFLICTS=$(git -C "$top" diff --name-only --diff-filter=U 2>/dev/null | head -20)
              git -C "$top" reset --merge >/dev/null 2>&1
              git -C "$top" reset --hard "$pre_sha" >/dev/null 2>&1
              post_sha="$pre_sha"; merged=0
              R_STATUS="stash-pop-conflict"
              R_BLOCKED_KIND="stash-pop-conflict"
              if git -C "$top" stash pop "$ref2" >/dev/null 2>&1; then
                note="合并后恢复改动会冲突，已整体回滚到同步前，改动已放回工作区"
              else
                # 别写"已恢复"——它没恢复。说清东西在哪、怎么拿回来。
                note="合并后恢复改动会冲突；合并已撤销，但你的改动还留在 stash 里没能放回工作区，用 git stash apply ${stash_sha} 取回"
              fi
            fi
          fi
        else
          R_STATUS="merge-conflict"
          R_BLOCKED_KIND="merge-conflict"
          note="$mb 合并到 $cur 有冲突，已 abort"
          if [ -n "$stash_ref" ]; then
            local ref2
            ref2=$(git -C "$top" stash list --format='%gd %H' 2>/dev/null | grep -F "$stash_sha" | head -1 | awk '{print $1}')
            [ -n "$ref2" ] || ref2="$stash_ref"
            if git -C "$top" stash pop "$ref2" >/dev/null 2>&1; then
              note="${note}，未提交改动已恢复"
            else
              note="${note}；但你的改动没能放回工作区，还在 stash 里，用 git stash apply ${stash_sha} 取回"
            fi
          fi
        fi
      fi
    fi
  fi

  # ── 阻塞记录收口 ──────────────────────────────────────────────────
  # 新出现的阻塞盖上时间戳（“卡了几天”从这一刻开始算）；合并成功就把记录清掉，
  # 免得下次拿着过期的结论说“还是老样子”。
  if [ -n "${R_BLOCKED_KIND:-}" ]; then
    if [ "${R_BLOCKED_SINCE:-0}" = "0" ]; then
      R_BLOCKED_SINCE=$(date +%s)
      R_BLOCKED_HEAD="$pre_sha"
      R_BLOCKED_MAIN="$main_after"
      R_STUCK_DAYS=0
    fi
  elif [ "$merged" = "1" ]; then
    R_BLOCKED_KIND=""; R_BLOCKED_HEAD=""; R_BLOCKED_MAIN=""; R_BLOCKED_SINCE=0; R_STUCK_DAYS=0
  fi

  [ -n "${R_STATUS:-}" ] || R_STATUS="ok"
  [ "$main_updated" = "0" ] && [ "$merged" = "0" ] && [ "$R_STATUS" = "ok" ] && R_STATUS="no-change"
  [ "$R_STATUS" = "branch-already-current" ] && [ "$main_updated" = "1" ] && R_STATUS="ok"

  write_report "$reportf" "$top" "$name" "$mb" "$cur" "$main_before" "$main_after" "$pre_sha" "$post_sha" "$merged" "$note"
  write_state "$statef" "$top" "$mb" "$cur" "$pre_sha" "$stash_sha"

  # short summary line
  local n_main=0 n_merged=0
  if [ -n "$main_before" ] && [ -n "$main_after" ] && [ "$main_before" != "$main_after" ]; then
    n_main=$(git -C "$top" rev-list --count "$main_before..$main_after" 2>/dev/null || echo 0)
  elif [ -z "$main_before" ] && [ -n "$main_after" ]; then
    n_main="新建"
  fi
  [ "$merged" = "1" ] && n_merged=$(git -C "$top" rev-list --count "$pre_sha..$post_sha" 2>/dev/null || echo 0)
  R_SUMMARY="$name [$cur] $mb +${n_main} 提交"
  [ "$merged" = "1" ] && R_SUMMARY="${R_SUMMARY}；已合并 ${n_merged} 个提交进 $cur"
  [ -n "$note" ] && R_SUMMARY="${R_SUMMARY}；$note"
  [ -n "${R_CONFLICTS:-}" ] && R_SUMMARY="${R_SUMMARY}；涉及文件：$(printf '%s' "${R_CONFLICTS}" | tr '\n' ' ')"
  if [ -n "${R_BLOCKED_KIND:-}" ] && [ "${R_STUCK_DAYS:-0}" -ge "$ESCALATE_DAYS" ] 2>/dev/null; then
    R_ESCALATED=1
    R_SUMMARY="【卡了 ${R_STUCK_DAYS} 天了】${R_SUMMARY}"
  fi
}

write_state() { # statef top mb cur pre_sha stash_sha
  local mbcache_at
  mbcache_at=$(date +%s)
  jq -n --arg path "$2" --arg mb "$3" --arg branch "$4" --arg pre "$5" --arg stash "$6" \
        --arg status "${R_STATUS:-}" --argjson at "$mbcache_at" \
        --arg bkind "${R_BLOCKED_KIND:-}" --arg bhead "${R_BLOCKED_HEAD:-}" \
        --arg bmain "${R_BLOCKED_MAIN:-}" --argjson bsince "${R_BLOCKED_SINCE:-0}" \
        --arg bfiles "${R_CONFLICTS:-}" \
    '{path:$path, default_branch:$mb, default_branch_at:$at, last_branch:$branch,
      last_pre_sha:$pre, last_stash_sha:$stash, last_status:$status,
      last_sync_epoch:$at,
      blocked_kind:$bkind, blocked_head:$bhead, blocked_main:$bmain,
      blocked_since:$bsince, blocked_files:$bfiles}' > "$1" 2>/dev/null
}

write_report() { # reportf top name mb cur main_before main_after pre post merged note
  local reportf="$1" top="$2" name="$3" mb="$4" cur="$5" mb_b="$6" mb_a="$7" pre="$8" post="$9" merged="${10}" note="${11}"
  {
    echo "# $name 同步报告"
    echo
    echo "- 时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "- 路径：$top"
    echo "- 主分支：$mb  当前分支：$cur"
    echo "- 状态：${R_STATUS:-ok}"
    [ -n "$note" ] && echo "- 备注：$note"
    echo
    if [ -n "$mb_b" ] && [ -n "$mb_a" ] && [ "$mb_b" != "$mb_a" ]; then
      echo "## $mb 新增提交（$(git -C "$top" rev-list --count "$mb_b..$mb_a") 个）"
      echo '```'
      git -C "$top" log --oneline --no-decorate "$mb_b..$mb_a" | head -40
      echo '```'
      echo
      echo "## 改动文件"
      echo '```'
      git -C "$top" diff --stat "$mb_b" "$mb_a" | tail -30
      echo '```'
      echo
      echo "## 提交者"
      echo '```'
      git -C "$top" shortlog -sn --no-merges "$mb_b..$mb_a" | head -15
      echo '```'
    elif [ -z "$mb_b" ] && [ -n "$mb_a" ]; then
      echo "## 本地 $mb 之前不存在，已从 origin 创建"
    else
      echo "## $mb 无新提交"
    fi
    echo
    if [ "$merged" = "1" ] && [ "$pre" != "$post" ]; then
      echo "## 合并进 $cur 的提交（$(git -C "$top" rev-list --count "$pre..$post") 个）"
      echo '```'
      git -C "$top" log --oneline --no-decorate "$pre..$post" | head -40
      echo '```'
      echo
      echo "- 合并前 HEAD：$pre"
      echo "- 合并后 HEAD：$post"
      echo "- 未推送（本分支现在领先 origin/${cur}，是否 push 由你决定）"
    else
      echo "## 未产生合并"
      echo
      if [ "${R_STATUS:-}" = "dirty-overlap" ]; then
        echo "没动手：你手上没提交的改动，正好落在这次要合进来的文件上。"
        echo "先合的话能合成，但把你的改动恢复回来时会撞车 —— 所以一步都没做，工作区原样。"
      elif [ "${R_STATUS:-}" = "merge-conflict" ] && [ -n "${R_CONFLICTS:-}" ]; then
        echo "没动手：预演（git merge-tree，只在内存里算）就发现会冲突。"
        echo "HEAD 仍是 ${pre}，工作区、stash 全没碰过。"
      elif [ -n "${R_CONFLICTS:-}" ]; then
        echo "合并有冲突，已整体回滚：HEAD 仍是 ${pre}，工作区和同步前一模一样，什么都没丢。"
      elif [ "${R_STATUS:-}" = "skipped-protected-branch" ]; then
        echo "当前分支在保护分支名单里，按配置不合并。"
      elif [ "${R_STATUS:-}" = "dirty-main-only" ] || [ "${R_STATUS:-}" = "skipped-dirty" ]; then
        echo "工作区有未提交改动，按配置 dirtyWorktree=${DIRTY_MODE} 跳过了合并。"
      elif [ "${cur}" = "${mb}" ]; then
        echo "当前就在 ${mb} 上，本来就不需要合并。"
      else
        echo "当前分支已经包含 ${mb} 的全部提交，无需合并。"
      fi
    fi
    if [ -n "${R_CONFLICTS:-}" ]; then
      echo
      if [ "${R_STATUS:-}" = "dirty-overlap" ]; then
        echo "## 撞车的文件（你改的 ∩ 要合进来的）"
      else
        echo "## 冲突文件（需要人工处理）"
      fi
      echo '```'
      printf '%s\n' "${R_CONFLICTS}"
      echo '```'
      echo
      if [ "${R_BLOCKED_SINCE:-0}" != "0" ]; then
        echo "- 卡住多久：${R_STUCK_DAYS} 天（从 $(date -r "${R_BLOCKED_SINCE}" '+%Y-%m-%d %H:%M' 2>/dev/null) 起）"
        echo "- 只要这两边的提交不变，之后每次启动都直接复用这个结论，不会再反复试。"
      fi
      echo
      if [ "${R_STATUS:-}" = "dirty-overlap" ]; then
        echo "处理办法：把手上的改动先提交或 stash 掉，再跑 /branch-sync 就能合了。"
      else
        echo "处理办法：手动 git merge ${mb} 复现冲突后逐个解决，或者叫 /branch-sync 让 Claude 接手。"
      fi
    fi
  } > "$reportf" 2>/dev/null
}

# ---------- run ----------
run_one_and_print() {
  sync_repo "$1"
  release_lock
  case "$MODE" in
    hook) : ;;
    *)
      echo "状态：${R_STATUS:-unknown}"
      [ -n "${R_SUMMARY:-}" ] && echo "摘要：$R_SUMMARY"
      [ -n "${R_REPORT_PATH:-}" ] && [ -f "$R_REPORT_PATH" ] && echo "报告：$R_REPORT_PATH"
      ;;
  esac
}

if [ "$ALL" = "1" ]; then
  root=$(cfg '.workspaceRoot')
  root="${root/#\~/$HOME}"
  if [ -z "$root" ]; then
    # 没配 workspaceRoot 就用「当前仓库的上一级目录」—— 把并排放着的仓库都扫一遍。
    # 多仓工作区通常就是这个形状，不必再让人配一次。
    local here
    here=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$here" ] && root=$(dirname "$here")
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "不知道要扫哪个目录：config 里没设 workspaceRoot，当前目录也不在 git 仓库里。"
    exit 0
  fi
  for d in "$root"/*/; do
    [ -d "$d/.git" ] || continue
    echo "=== $(basename "$d") ==="
    run_one_and_print "$d"
    echo
  done
  exit 0
fi

sync_repo "$TARGET"
release_lock

if [ "$MODE" = "hook" ]; then
  case "${R_STATUS:-}" in
    ok|dirty-stashed|merge-conflict|dirty-overlap|stash-pop-conflict|main-diverged|fetch-failed|stash-failed|dirty-main-only)
      urgent=""
      if [ "${R_ESCALATED:-0}" = "1" ]; then
        urgent="
【必须放在第一句】这个仓已经卡了 ${R_STUCK_DAYS} 天没能合上主分支，超过了 ${ESCALATE_DAYS} 天的阈值。
不要一笔带过 —— 明确告诉用户卡了多久、卡在哪几个文件上，并直接问他要不要现在处理。
冲突拖得越久越难解，这正是它该被当回事的原因。"
      fi
      ctx="[branch-sync] ${R_SUMMARY:-}
状态：${R_STATUS}  完整报告：${R_REPORT_PATH:-无}
${urgent}
说明：这是会话启动时自动跑的仓库同步。请在你对用户的第一条回复开头，用两三句中文人话说清：主分支带来了什么变化、有没有合进当前分支、有没有出岔子需要处理。如果状态是 merge-conflict / dirty-overlap，说明脚本是靠只读预演发现问题的，**一步都没动手**，工作区原样；
如果是 stash-pop-conflict / main-diverged / fetch-failed，说明工作区已整体回滚到同步前。两种都可以叫 /branch-sync 让你接手。"
      jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
      ;;
    *) : ;;   # no-change / not-a-repo / skipped-* : stay silent
  esac
  exit 0
fi

if [ "$REPORT_ONLY" = "1" ]; then
  if [ -n "${R_REPORT_PATH:-}" ] && [ -f "${R_REPORT_PATH:-}" ]; then
    cat "$R_REPORT_PATH"
  else
    echo "还没有报告：${R_REPORT_PATH:-当前目录不是 git 仓库}"
  fi
  exit 0
fi

echo "状态：${R_STATUS:-unknown}"
[ -n "${R_SUMMARY:-}" ] && echo "摘要：$R_SUMMARY"
if [ -n "${R_REPORT_PATH:-}" ] && [ -f "${R_REPORT_PATH:-}" ]; then
  echo "报告：$R_REPORT_PATH"
  echo "---"
  cat "$R_REPORT_PATH"
fi
exit 0
