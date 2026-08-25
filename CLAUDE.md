# Contributing notes / 给改这个仓的人

## Shape

```
skills/session-sync/scripts/sync.sh    ← 全部同步逻辑，钩子和技能共用同一份
skills/repo-inbox/scripts/inbox.sh     ← 一次 GraphQL 查询 + jq 过滤
skills/*/SKILL.md                      ← 给 Claude 看的：什么时候用、怎么汇报、出岔子怎么办
hooks/hooks.json                       ← 插件形态的会话启动钩子
install.sh                             ← 手动形态：软链 + 写钩子 + 生成配置
```

运行时数据（`config.json` / `state/` / `reports/`）只存在于 `~/.claude/session-init/`，
永远不进这个仓库。

## 三个非改不可的约定

**一、只读预演不能拆。** `sync.sh` 在动手之前必须先用 `git merge-tree` 算一遍，再比一次
「未提交的文件 ∩ 要合进来的文件」。这两道过了才允许 stash / merge。回滚逻辑是保险丝，不是
可以依赖的主路径——别因为「反正有回滚」就把预演去掉。

**二、绝不 push。** 任何情况下都不要在脚本里加 `git push`。

**三、失败必须原样归位。** 每条失败路径结束时，工作区和 `HEAD` 必须和动手前一模一样，
不留 `MERGE_HEAD`、不留孤儿 stash。

## 两个反复踩到的坑

**bash 3.2（macOS 自带的唯一一个）按字节判断变量名边界。** `"$mb：主分支"` 里的 `$mb` 会把
后面中文的首字节吞进变量名，`set -u` 下直接退出——而且如果发生在被 `2>/dev/null` 吞掉的代码
块里，现象是「脚本无声中断、文件只写了一半」，极难定位。**变量后面紧跟非 ASCII 字符一律写
`${var}`**。同理 bash 3.2 没有 `mapfile`，用 `while IFS= read -r x; do ... done < <(...)`。

**jq 的假值。** `//` 把 `false` 当成「不存在」，`if` 把 `0` 当成真。这两条各坑过一次：
`.enabled // empty` 让 `"enabled": false` 永远关不掉仓库；`--argjson showAll 0` 让 `if $showAll`
永远成立。取布尔值一律写成 `if (.x) == false then "false" else "true" end`，传标志位一律传
`true`/`false` 字符串而不是 `0`/`1`。

## 怎么测

`SESSION_INIT_DIR` 可以把配置/状态/报告整体挪到临时目录，测试全程不碰真实状态：

```bash
export SESSION_INIT_DIR=/tmp/si-test
mkdir -p "$SESSION_INIT_DIR"/{state,reports}
cp config.example.json "$SESSION_INIT_DIR/config.json"
```

边缘场景都能在本地造出来，不需要网络：

| 场景 | 怎么造 |
| --- | --- |
| `fetch-failed` | `git remote set-url origin /path/that/does/not/exist.git` |
| `main-diverged` | 本地主分支上多一个提交，同时远端也往前走了 |
| `no-default-branch` | 上游只留一个非 main/master 的分支，并 `git remote set-head origin -d` |
| `stash-failed` | `touch .git/index.lock` |
| `skipped-detached` | `git checkout --detach HEAD` |

**验证「真的没动手」不能靠 `git stash list` 或 stash reflog**——pop 成功之后这两处都会被清空，
走过 stash 的仓和从没 stash 过的仓看起来一模一样。可靠的办法是拦下脚本发出的每一条 git 命令：

```bash
mkdir -p /tmp/shim
printf '#!/bin/sh\necho "$@" >> "$GIT_TRACE_FILE"\nexec %s "$@"\n' "$(command -v git)" > /tmp/shim/git
chmod +x /tmp/shim/git
GIT_TRACE_FILE=/tmp/trace.log PATH="/tmp/shim:$PATH" ./skills/session-sync/scripts/sync.sh --force --repo /path/to/repo
grep -cE '(^| )(stash|merge|reset|checkout|rebase|commit)( |$)' /tmp/trace.log   # 冲突场景必须是 0
```

对照组很重要：拿一个「脏但不撞车」的仓跑同一套，计数应该是非零——证明这个探针确实抓得到。

## 提交风格

常规 commit（`feat:` / `fix:` / `docs:` / `chore:`），主题用英文小写开头，不用 gitmoji。
