#!/usr/bin/env bash
# repo-inbox: 查「我发起的 PR / issue / discussion 有没有人回复、有没有人评审」
# 一次 GraphQL 拉全，按上次查看时间做增量，输出 JSON 交给 Claude 翻译成人话。
set -uo pipefail

# SESSION_INIT_DIR 可以把配置/状态/报告整体挪走 —— 测试时用它做隔离，
# 免得把真实配置和状态搅进来。日常不用设。
CONFIG_DIR="${SESSION_INIT_DIR:-$HOME/.claude/session-init}"
CONFIG_FILE="$CONFIG_DIR/config.json"
SEEN_FILE="$CONFIG_DIR/state/inbox-seen.json"
mkdir -p "$CONFIG_DIR/state"
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE"

SHOW_ALL=0
MARK=1
REPO_FILTER=""
FORCE_ORG=0
CWD_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     SHOW_ALL=1; MARK=0 ;;
    --no-mark) MARK=0 ;;
    --org)     FORCE_ORG=1 ;;
    --repo)    shift; REPO_FILTER="${1:-}" ;;
    --cwd)     shift; CWD_OVERRIDE="${1:-}" ;;
    *)         ;;
  esac
  shift
done

command -v gh >/dev/null 2>&1 || { echo '{"error":"gh 未安装"}'; exit 0; }
gh auth status >/dev/null 2>&1 || { echo '{"error":"gh 未登录，先跑 gh auth login"}'; exit 0; }

cfg() { jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null; }
# 只用于「已关闭/已合并」那一组：开着的东西不受时间限制
LOOKBACK=$(cfg '.inbox.closedLookbackDays')
[ -n "$LOOKBACK" ] || LOOKBACK=$(cfg '.inbox.lookbackDays')
[ -n "$LOOKBACK" ] || LOOKBACK=30
# 同样不能用 `// true`：jq 会把 false 当缺省，导致 includeCI:false 关不掉
INCLUDE_CI=$(jq -r 'if (.inbox.includeCI) == false then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null)

# 当前所在仓库 → owner/name。支持 https 和 git@ 两种 remote 写法。
detect_repo() {
  local dir url
  dir="${CWD_OVERRIDE:-$PWD}"
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  printf '%s' "$url" \
    | sed -E 's#^git@github\.com:#https://github.com/#' \
    | sed -E 's#^ssh://git@github\.com/#https://github.com/#' \
    | sed -E 's#^https://[^/]*github\.com/##; s#\.git$##; s#/+$##'
}

# 组织名只有两个用途：`--org` 的范围、`--repo <短名>` 补全 owner。
# 优先读配置；没配就从当前仓库的 owner 推出来，所以多数情况根本不用配。
ORG=$(cfg '.inbox.org')
[ -n "$ORG" ] || ORG=$(cfg '.inbox.scope' | sed -E 's/^org://')
if [ -z "$ORG" ]; then
  _d=$(detect_repo); ORG="${_d%%/*}"
fi

# 作用域：默认跟着你当前所在的项目走。
#   - --repo <名>  显式指定某个仓（owner 用配置里的组织补全）
#   - --org        强制查整个组织
#   - 不在 git 仓库里（比如多仓工作区的根目录）→ 退回整个组织，并在输出里说明
SCOPE_KIND="repo"
SCOPE_LABEL=""
if [ "$FORCE_ORG" = "1" ] && [ -z "$ORG" ]; then
  echo '{"error":"--org 需要知道组织名，但配置里没设 inbox.org，当前目录也不在 git 仓库里"}'
  exit 0
fi
if [ -n "$REPO_FILTER" ]; then
  case "$REPO_FILTER" in
    */*) SCOPE_LABEL="$REPO_FILTER" ;;
    *)   SCOPE_LABEL="$ORG/$REPO_FILTER" ;;
  esac
  SCOPE_Q="repo:$SCOPE_LABEL"
  SCOPE_SRC="--repo 指定"
elif [ "$FORCE_ORG" = "1" ]; then
  SCOPE_KIND="org"; SCOPE_LABEL="$ORG"; SCOPE_Q="org:$ORG"; SCOPE_SRC="--org 指定"
else
  DETECTED=$(detect_repo)
  if [ -n "$DETECTED" ]; then
    SCOPE_LABEL="$DETECTED"; SCOPE_Q="repo:$DETECTED"; SCOPE_SRC="当前所在仓库"
  else
    SCOPE_KIND="org"; SCOPE_LABEL="$ORG"; SCOPE_Q="org:$ORG"
    SCOPE_SRC="当前目录不是 git 仓库，退回整个组织"
  fi
fi
SCOPE="$SCOPE_Q"

# 判断标准是**状态**，不是时间：
#   - 还开着的 PR / issue：一律全查，不管开了多久。自己开的东西没关掉就是还没了结。
#   - 已关闭 / 已合并的：只看最近还有动静的（人常在合并后才补评审意见），这里才需要一道窗。
#   - discussion：没有开关状态，量也小，全查。
SINCE=$(date -v-"${LOOKBACK}"d +%Y-%m-%d 2>/dev/null || date -d "-${LOOKBACK} days" +%Y-%m-%d)
PRQ="$SCOPE author:@me is:pr is:open"
PRCQ="$SCOPE author:@me is:pr is:closed updated:>=$SINCE"
ISQ="$SCOPE author:@me is:issue is:open"
ISCQ="$SCOPE author:@me is:issue is:closed updated:>=$SINCE"
DSQ="$SCOPE author:@me"

read -r -d '' GQL <<'GQL_EOF'
query($prq:String!, $prcq:String!, $isq:String!, $iscq:String!, $dsq:String!) {
  viewer { login }
  prs: search(query:$prq, type:ISSUE, first:100) {
    issueCount
    nodes { ... on PullRequest {
      number title url createdAt updatedAt state isDraft
      repository { nameWithOwner }
      comments(last:30) { nodes { author{login} createdAt url bodyText } }
      reviews(last:20) { nodes { author{login} state createdAt url bodyText } }
      reviewThreads(last:30) { nodes {
        isResolved path line
        comments(first:20) { nodes { author{login} createdAt url bodyText } }
      } }
      commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
    } }
  }
  prsClosed: search(query:$prcq, type:ISSUE, first:100) {
    issueCount
    nodes { ... on PullRequest {
      number title url createdAt updatedAt state isDraft
      repository { nameWithOwner }
      comments(last:30) { nodes { author{login} createdAt url bodyText } }
      reviews(last:20) { nodes { author{login} state createdAt url bodyText } }
      reviewThreads(last:30) { nodes {
        isResolved path line
        comments(first:20) { nodes { author{login} createdAt url bodyText } }
      } }
      commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
    } }
  }
  issues: search(query:$isq, type:ISSUE, first:100) {
    issueCount
    nodes { ... on Issue {
      number title url createdAt updatedAt state
      repository { nameWithOwner }
      comments(last:30) { nodes { author{login} createdAt url bodyText } }
    } }
  }
  issuesClosed: search(query:$iscq, type:ISSUE, first:100) {
    issueCount
    nodes { ... on Issue {
      number title url createdAt updatedAt state
      repository { nameWithOwner }
      comments(last:30) { nodes { author{login} createdAt url bodyText } }
    } }
  }
  discussions: search(query:$dsq, type:DISCUSSION, first:100) {
    discussionCount
    nodes { ... on Discussion {
      number title url createdAt updatedAt
      repository { nameWithOwner }
      comments(last:20) { nodes {
        author{login} createdAt url bodyText
        replies(last:10) { nodes { author{login} createdAt url bodyText } }
      } }
    } }
  }
}
GQL_EOF

RAW=$(gh api graphql -f query="$GQL" -f prq="$PRQ" -f prcq="$PRCQ" -f isq="$ISQ" -f iscq="$ISCQ" -f dsq="$DSQ" 2>&1)
if ! printf '%s' "$RAW" | jq -e '.data' >/dev/null 2>&1; then
  jq -n --arg e "$RAW" '{error:"GraphQL 查询失败", detail:$e}'
  exit 0
fi

RESULT=$(printf '%s' "$RAW" | jq \
  --slurpfile seenArr "$SEEN_FILE" \
  --argjson showAll "$([ "$SHOW_ALL" = "1" ] && echo true || echo false)" \
  --arg repoFilter "" \
  --argjson now "$(date +%s)" \
  --argjson includeCI "$([ "$INCLUDE_CI" = "false" ] && echo false || echo true)" '
  .data as $d
  | ($d.viewer.login) as $me
  | ($seenArr[0] // {}) as $seen
  | def clip: if (. // "") | length > 700 then .[0:700] + " …(截断)" else (. // "") end;
    def notme($a): ($a.login // "ghost") != $me;

    def prEvents:
      ( [ .comments.nodes[]? | select(notme(.author))
          | {kind:"comment", author:.author.login, at:.createdAt, url:.url, body:(.bodyText|clip), ctx:null} ]
      + [ .reviews.nodes[]? | select(notme(.author)) | select(.state != "PENDING")
          | {kind:("review:" + .state), author:.author.login, at:.createdAt, url:.url, body:(.bodyText|clip), ctx:null} ]
      + [ .reviewThreads.nodes[]? | select(.isResolved | not) as $t
          | $t.comments.nodes[]? | select(notme(.author))
          | {kind:"review-comment", author:.author.login, at:.createdAt, url:.url, body:(.bodyText|clip),
             ctx:(($t.path // "?") + ":" + (($t.line // 0)|tostring))} ] );

    def dsEvents:
      ( [ .comments.nodes[]? | select(notme(.author))
          | {kind:"comment", author:.author.login, at:.createdAt, url:.url, body:(.bodyText|clip), ctx:null} ]
      + [ .comments.nodes[]? | .replies.nodes[]? | select(notme(.author))
          | {kind:"reply", author:.author.login, at:.createdAt, url:.url, body:(.bodyText|clip), ctx:null} ] );

    def allTimes:
      ( [ .comments.nodes[]?.createdAt ]
      + [ .reviews.nodes[]?.createdAt ]
      + [ .reviewThreads.nodes[]?.comments.nodes[]?.createdAt ]
      + [ .comments.nodes[]?.replies.nodes[]?.createdAt ] | map(select(. != null)) );

    def build($type):
      { type:$type,
        repo:.repository.nameWithOwner,
        number:.number, title:.title, url:.url,
        state:(.state // "OPEN"),
        isDraft:(.isDraft // false),
        createdAt:.createdAt,
        updatedAt:.updatedAt,
        ci:(if $includeCI then (.commits.nodes[0].commit.statusCheckRollup.state // null) else null end),
        key:(.repository.nameWithOwner + "#" + ($type) + "#" + (.number|tostring)),
        events:(if $type == "discussion" then dsEvents else prEvents end),
        everAnswered:((if $type == "discussion" then dsEvents else prEvents end) | length > 0),
        maxSeen:(allTimes | max // "1970-01-01T00:00:00Z") };

    ( [ $d.prs.nodes[]?          | select(.number != null) | build("pr") ]
    + [ $d.prsClosed.nodes[]?    | select(.number != null) | build("pr") ]
    + [ $d.issues.nodes[]?       | select(.number != null) | build("issue") ]
    + [ $d.issuesClosed.nodes[]? | select(.number != null) | build("issue") ]
    + [ $d.discussions.nodes[]?  | select(.number != null) | build("discussion") ] )
    | unique_by(.key)
  | map(select($repoFilter == "" or (.repo | endswith("/" + $repoFilter))))
  | map( ($seen[.key] // "1970-01-01T00:00:00Z") as $last
         | .lastSeen = $last
         | .newEvents = ( if $showAll then .events
                          else [ .events[] | select(.at > $last) ] end
                          | sort_by(.at) ) )
  | ( map(select(.state == "OPEN" and (.newEvents | length) == 0
                 and (($includeCI | not) or (.ci != "FAILURE" and .ci != "ERROR"))))
      | map({ repo, type, number, title, url, ci,
              draft: .isDraft,
              openDays: (if (.createdAt|type) == "string" then (($now - (.createdAt|fromdateiso8601)) / 86400 | floor) else null end),
              quietDays: (if (.updatedAt|type) == "string" then (($now - (.updatedAt|fromdateiso8601)) / 86400 | floor) else null end),
              everAnswered })
      | sort_by(-(.quietDays // 0)) ) as $quiet
  | map(select((.newEvents | length) > 0
               or ($includeCI and .state == "OPEN" and (.ci == "FAILURE" or .ci == "ERROR"))))
  | { viewer:$me,
      openNoNewReplies: $quiet,
      scope:"'"$SCOPE_LABEL"'",
      scopeKind:"'"$SCOPE_KIND"'",
      scopeReason:"'"$SCOPE_SRC"'",
      mode:(if $showAll then "全部" else "增量（只显示上次查看之后的新内容）" end),
      threads: (. | sort_by(.updatedAt) | reverse),
      truncated: ( [ (if ($d.prs.issueCount // 0)          > ($d.prs.nodes|length)          then "开着的 PR" else empty end),
                     (if ($d.prsClosed.issueCount // 0)    > ($d.prsClosed.nodes|length)    then "已关闭的 PR" else empty end),
                     (if ($d.issues.issueCount // 0)       > ($d.issues.nodes|length)       then "开着的 issue" else empty end),
                     (if ($d.issuesClosed.issueCount // 0) > ($d.issuesClosed.nodes|length) then "已关闭的 issue" else empty end),
                     (if ($d.discussions.discussionCount // 0) > ($d.discussions.nodes|length) then "discussion" else empty end) ] ),
      counts: { threads:length,
                openNoNewReplies:($quiet|length),
                newEvents:(map(.newEvents|length)|add // 0),
                ciFailing:(map(select(.state == "OPEN" and (.ci == "FAILURE" or .ci == "ERROR")))|length) },
      seenUpdate: (map({(.key): .maxSeen}) | add // {}) }
')

# ── 长期卡住的仓也一起报 ──────────────────────────────────────────
# session-sync 每次启动都会把「合不上主分支」的仓记进 state。那种提示混在启动
# 信息里容易被划过去，所以在这里再报一次：收件箱是专门用来看「有什么等着我处理」的。
# 当前仓的绝对路径 —— 用来把 blockedRepos 也收敛到同一个作用域
REPO_TOP=""
[ "$SCOPE_KIND" = "repo" ] && REPO_TOP=$(git -C "${CWD_OVERRIDE:-$PWD}" rev-parse --show-toplevel 2>/dev/null)

BLOCKED='[]'
if ls "$CONFIG_DIR"/state/*.json >/dev/null 2>&1; then
  BLOCKED=$(jq -s --argjson now "$(date +%s)" --arg top "$REPO_TOP" '
    [ .[]
      | select((.blocked_kind // "") != "")
      | select($top == "" or (.path // "") == $top)
      | { repo: (.path // "" | split("/") | last),
          path: .path,
          branch: .last_branch,
          kind: .blocked_kind,
          files: ((.blocked_files // "") | split("\n") | map(select(length > 0))),
          stuckDays: (if (.blocked_since // 0) > 0 then (($now - .blocked_since) / 86400 | floor) else 0 end) }
    ] | sort_by(-.stuckDays)' "$CONFIG_DIR"/state/*.json 2>/dev/null)
  [ -n "$BLOCKED" ] || BLOCKED='[]'
fi

# events 与 newEvents 在 --all 下完全重复，只留 newEvents，省掉一半篇幅
printf '%s\n' "$RESULT" | jq --argjson blocked "$BLOCKED" '
  del(.seenUpdate)
  | .threads |= map(del(.events, .maxSeen))
  | .blockedRepos = $blocked
  | .counts.blockedRepos = ($blocked | length)'

if [ "$MARK" = "1" ]; then
  printf '%s' "$RESULT" | jq '.seenUpdate' > "$CONFIG_DIR/state/.inbox-new.json" 2>/dev/null
  if jq -e . "$CONFIG_DIR/state/.inbox-new.json" >/dev/null 2>&1; then
    jq -s '.[0] * .[1]' "$SEEN_FILE" "$CONFIG_DIR/state/.inbox-new.json" > "$SEEN_FILE.tmp" 2>/dev/null \
      && mv "$SEEN_FILE.tmp" "$SEEN_FILE"
  fi
  rm -f "$CONFIG_DIR/state/.inbox-new.json"
fi
exit 0
