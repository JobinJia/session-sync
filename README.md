# branch-sync

Two Claude Code skills that take care of the two things you do at the start of every working
session: get the repo you are in up to date, and find out whether anyone replied to what you
opened.

两个 Claude Code 技能，管的是每次开工前都要做的两件事：把手头这个仓库更新到最新，以及看看你开的
PR / issue / discussion 有没有人回。

> 本文档中英双语：每节先英文，后中文。

---

## What it does / 它做什么

**`branch-sync`** — runs automatically when a session starts (and on demand). It fast-forwards
your local default branch from `origin`, merges it into the branch you are working on, and
explains in plain language what changed. When it cannot merge cleanly it says so and changes
nothing.

**`repo-inbox`** — on demand. Shows who replied to or reviewed the PRs, issues and discussions
**you** opened, pulls the actual comment text down, and flags failing CI and anything still open
that nobody has touched.

**`branch-sync`** —— 会话启动时自动跑（也可以手动触发）。把本地主分支从 `origin` 快进到最新，
再合进你正在写的分支，然后用人话说清这次变了什么。合不干净的时候它会说出来，并且什么都不改。

**`repo-inbox`** —— 手动触发。看**你自己**开的 PR / issue / discussion 有没有人回复、有没有人
评审，把评论原文拉下来，顺带报 CI 红灯和那些还开着却没人理的东西。

---

## The part that matters: it does not gamble with your worktree

The obvious way to build this is: stash your uncommitted work, merge, pop the stash, and roll
back if anything explodes. That works, but it means every session start really does run a merge
across your working tree and hopes the rollback is good enough.

This does it the other way round. Before touching anything it computes the merge **in memory**
with `git merge-tree` — a read-only operation — and only proceeds when the result is provably
clean. It also compares the files you have edited but not committed against the files the merge
would bring in, because `merge-tree` cannot see uncommitted work; if they overlap, it stops.

So on the paths that would have been dangerous, **zero write-class git commands run at all**.
Verified by intercepting every `git` invocation the script makes: on a conflict, and on a
dirty-overlap, the count is zero. The rollback logic is still there, but it is a fuse now, not
the main path.

### 这一点是重点：它不拿你的工作区赌

顺手的写法是：把没提交的改动 stash 起来，合并，再 pop 回来，出事就回滚。能用，但那意味着**每次
会话启动都真的在你的工作树上跑了一遍合并**，然后指望回滚足够干净。

这里反过来做。动手之前先用 `git merge-tree` 在内存里把合并算出来——纯只读——只有算出来确实干净才
往下走。另外还比一次：你改了但没提交的文件，和这次要合进来的文件有没有交集（`merge-tree` 看不见
没提交的东西）。有交集就停手。

于是在那些原本危险的路径上，**一条写操作类的 git 命令都不会执行**。这是用拦截脚本发出的每一条
`git` 调用验证过的：冲突场景和撞车场景，计数都是零。回滚逻辑还在，但它现在是保险丝，不是主路径。

---

## Two more things it does when it gets stuck / 卡住时的另外两件事

**It does not spin on the same blockage.** When a merge cannot happen, it records the pair of
commits that produced it. Next session, if neither side moved, it reuses that conclusion instead
of recomputing, and reports how many days it has been stuck.

**It gets louder over time.** Past `blockedEscalateDays` (default 7), the context injected at
session start carries an explicit instruction to lead with the problem rather than mention it in
passing. A conflict gets harder to resolve the longer it sits, which is exactly why it should
not stay quiet.

**同一个阻塞不重复空转。** 合不上的时候，它把「当时两边的提交」这一对记下来。下次启动如果两边都
没动过，就直接复用上次的结论，不再重算，并且报出已经卡了几天。

**卡得越久声音越大。** 超过 `blockedEscalateDays`（默认 7 天），启动时注入的上下文里会带一条明确
指令，要求把这件事放在第一句说，而不是一笔带过。冲突拖得越久越难解，这正是它不该安静的理由。

---

## Install / 安装

### As a plugin / 作为插件

```
/plugin marketplace add JobinJia/branch-sync
/plugin install branch-sync@jobinjia
```

The plugin ships the session-start hook with it, so nothing else is needed.

插件自带会话启动钩子，装完即可。

### By hand / 手动

```bash
git clone https://github.com/JobinJia/branch-sync.git ~/myself/branch-sync
~/myself/branch-sync/install.sh
```

`install.sh` symlinks both skills into `~/.claude/skills/`, appends one `SessionStart` hook to
`~/.claude/settings.json` (existing hooks are left alone, and the file is backed up first), and
seeds a default config. It is idempotent; `install.sh --uninstall` reverses it.

`install.sh` 会把两个技能软链进 `~/.claude/skills/`，往 `~/.claude/settings.json` 的
`SessionStart` 里**追加**一条钩子（已有的钩子不动，改之前先备份），并生成一份默认配置。可重复
执行；`install.sh --uninstall` 原样撤掉。

### Requirements / 依赖

`git` (2.38+, for `merge-tree --write-tree`), `jq`, and `gh` (logged in) for `repo-inbox`.

`git`（2.38 以上，要用 `merge-tree --write-tree`）、`jq`，`repo-inbox` 还需要登录过的 `gh`。

---

## Configuration / 配置

Everything lives in `~/.claude/branch-sync/config.json`; see `config.example.json`.
配置只有一份，在 `~/.claude/branch-sync/config.json`，样例见 `config.example.json`。

| Key | Default | What it does / 作用 |
| --- | --- | --- |
| `onSessionStart.freshnessMinutes` | `15` | Skip if this repo was synced within N minutes — several sessions in a row will not refetch. 这个仓 N 分钟内同步过就跳过，连开几个会话不会反复拉。 |
| `dirtyWorktree` | `stash` | `stash` / `mainOnly` (update the default branch only) / `skip`. |
| `mergeStrategy` | `merge` | `merge` or `rebase`. |
| `protectedBranches` | `main, master, release/*` | Never merged into. 这些分支上不做合并。 |
| `blockedEscalateDays` | `7` | When a blockage starts being reported loudly. 阻塞多久之后开始大声报。 |
| `repos.<name>.defaultBranch` | — | Override when the remote's idea of the default branch is wrong. 远端的默认分支不可信时用它覆盖。 |
| `repos.<name>.enabled` | — | Set `false` to skip a repo entirely. 设成 `false` 就整仓跳过。 |
| `workspaceRoot` | — | Only used by `--all`. Empty means "the directory holding the current repo". 只给 `--all` 用；留空就是「当前仓库的上一级目录」。 |
| `inbox.org` | — | Only used by `--org` and to complete `--repo <short-name>`. Derived from the current remote when empty. 只给 `--org` 和 `--repo <短名>` 补全用；留空就从当前仓的 remote 推。 |
| `inbox.closedLookbackDays` | `30` | How far back to look **for closed/merged items**. Open ones are never filtered by age. 只作用于**已关闭/已合并**的；开着的东西不按时间筛。 |

`BRANCH_SYNC_DIR` relocates config, state and reports as a set — used by the test suite so it
never touches your real state.
`BRANCH_SYNC_DIR` 可以把配置、状态、报告整体挪走，测试就是靠它做隔离，不碰你真实的状态。

---

## Usage / 用法

```
/branch-sync              sync now and explain what changed   同步并说清变了什么
/branch-sync --dry-run    print the plan, touch nothing       只打印计划，什么都不碰
/branch-sync --report     re-read the last report             回看上次的报告
/branch-sync --all        sweep every repo in the workspace   扫工作区里所有仓

/repo-inbox                who replied, in this repo           谁回了我（当前仓）
/repo-inbox --org          across the whole org                整个组织
/repo-inbox --repo <name>  a specific repo                     指定某个仓
/repo-inbox --no-mark      look without marking as read        看了但不标记已读
```

`repo-inbox` is scoped to the repo the session is in. Run it inside a project and you get that
project only; the repo is derived from the `origin` remote, so a repo that lives under a
different org than the rest is not silently missed.

`repo-inbox` 的范围跟着当前所在的仓走。在哪个项目里用就只出那个项目的东西；仓库是从 `origin`
的 remote 推出来的，所以工作区里个别属于别的组织的仓不会被无声漏掉。

---

## Status codes / 状态码

`branch-sync` reports one of these; the skill tells Claude what to do with each.
`branch-sync` 会报出其中一个，技能文档里写了每种该怎么处理。

| Code | Meaning / 含义 |
| --- | --- |
| `ok` / `no-change` | Merged, or already current. 合上了，或本来就是最新。 |
| `dirty-stashed` | Stashed, merged, restored — worktree identical. 已 stash → 合并 → 恢复，工作区原样。 |
| `merge-conflict` | Would conflict. **Nothing was touched.** 会冲突，**一步没动手**。 |
| `dirty-overlap` | Your uncommitted edits sit on files the merge brings in. **Nothing was touched.** 你没提交的改动落在要合进来的文件上，**一步没动手**。 |
| `stash-pop-conflict` | The fuse tripped: merge undone, stash restored, back to the start. 保险丝跳了：合并撤销、改动恢复、回到起点。 |
| `main-diverged` | Local default branch cannot fast-forward. 本地主分支无法快进。 |
| `fetch-failed` / `no-remote` / `no-default-branch` | Could not even get that far. 连这一步都没走到。 |
| `skipped-*` | Fresh / detached HEAD / protected / disabled / dirty-by-config. 新鲜期内 / HEAD 游离 / 保护分支 / 整仓禁用 / 按配置跳过。 |

---

## What it will never do / 它绝不会做的事

- `git push` — merging leaves your branch ahead of the remote; pushing is your call.
- Resolve a conflict on its own.
- Leave a half-finished merge or an orphaned stash behind. Every failure path returns the
  worktree and `HEAD` to exactly where they were.

- `git push` —— 合并之后你的分支领先远端，推不推是你的决定。
- 自己解决冲突。
- 留下半截的合并或者没人认领的 stash。每一条失败路径都会把工作区和 `HEAD` 还原到动手之前。

---

## License

MIT
