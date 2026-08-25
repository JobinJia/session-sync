---
name: branch-sync
description: 'Sync the current git repo: fast-forward the local default branch from origin and merge it into the working branch, then explain what changed. Use when the user asks to 同步代码 / 更新代码 / 拉一下主分支 / 把 main 合进来 / 更新一下这个仓 / sync / pull latest, or mentions "/branch-sync". Also use to interpret or act on a session-start sync report (状态 merge-conflict / stash-pop-conflict / main-diverged / fetch-failed), or to review what the automatic startup sync did. The same script also runs automatically at session start via a SessionStart hook.'
allowed-tools: Bash, Read, Edit
---

# branch-sync — 把当前仓库同步到最新

一句话：把远端主分支拉到本地，再合进你正在写的分支，然后用人话告诉你变了什么。
会话启动时由 `SessionStart` 钩子自动跑一遍；这个技能是同一套脚本的手动入口，外加「出岔子了帮你收拾」。

脚本：`~/.claude/skills/branch-sync/scripts/sync.sh`
配置：`~/.claude/branch-sync/config.json`
报告：`~/.claude/branch-sync/reports/<仓名>.md`

## 怎么用

| 用户说什么 | 你跑什么 |
| --- | --- |
| 同步一下 / 更新代码 / 拉最新的 | `sync.sh --force` |
| 刚才启动时同步了啥 / 看下报告 | `sync.sh --report`（不重跑，只读上次报告） |
| 把工作区下所有仓都同步一遍 | `sync.sh --all`（**只有用户明确要求才跑**，逐个串行，仓多就慢） |
| 只同步某个仓 | `sync.sh --force --repo <绝对路径>` |
| 先看看会做什么 / 会不会动我的改动 | `sync.sh --dry-run --force`（只打印计划，不碰网络也不碰仓库） |
| 改配置 / 关掉自动同步 / 改主分支 | 编辑 `~/.claude/branch-sync/config.json`（`sync.sh --config` 打印路径） |

脚本自己会打印「状态 / 摘要 / 完整报告」，你**不要**把报告原样贴给用户。要做的是：

1. 读报告里的提交清单和改动文件，**用中文说清楚这次主分支带来了什么**——哪个模块动了、有没有接口变化、对用户当前分支上正在做的事有没有影响。别念 commit hash。
2. 提交多的时候（>15 个）按主题归类讲，别逐条列。
3. 没有任何更新时就一句「已经是最新的」，不要展开。

## 出岔子时怎么办

脚本只做**确定性的安全操作**，一遇到需要判断的情况就整体回滚并打状态码。看到这些状态时接手：

| 状态 | 含义 | 你该做什么 |
| --- | --- | --- |
| `merge-conflict` | 主分支合进当前分支会冲突 | **脚本是靠只读预演发现的，一步都没动手**，工作区/HEAD/stash 全没碰过。报告里有冲突文件清单。先看冲突内容（`git merge <主分支>` 复现），分析两边改了什么，**给出方案后问用户要不要动手**，不要擅自解决冲突 |
| `dirty-overlap` | 用户没提交的改动，正好落在这次要合进来的文件上 | 同样一步没动手。合得成，但恢复改动时会撞车。告诉用户：把手上的改动先提交或 stash 掉，再跑一次就能合 |
| `stash-pop-conflict` | 合并成功但恢复未提交改动会冲突，已整体回滚 | 工作区和 HEAD 都回到同步前，什么都没丢。告诉用户：先把手头改动提交掉，再重跑 `/branch-sync` |
| `main-diverged` | 本地主分支和远端分歧，没法快进 | 大概率本地主分支上有不该有的提交。查 `git log origin/<主分支>..<主分支>`，告诉用户多出了什么，问要不要 reset |
| `fetch-failed` | 拉不到远端 | 网络或权限问题，把 git 的报错原文给用户 |
| `dirty-main-only` / `skipped-dirty` | 工作区脏，按配置只更新了主分支 | 告诉用户提交或 stash 后再同步 |
| `no-default-branch` | 认不出主分支 | 让用户在 config 的 `repos.<仓名>.defaultBranch` 里指定 |

**任何状态下都不要自动 `git push`。** 合并后本地分支领先远端，推不推是用户的决定。

## 三层兜底（改动前必须理解，别拆掉）

**一、先算后斩。** 动手之前先用 `git merge-tree` 在内存里把合并算一遍 —— 这是纯只读的，不碰工作区、不 stash、不留中间态。只有算出来干净才会真动手。再加一道：比对「用户没提交的改动」和「这次要合进来的文件」有没有交集，有交集也不动手（`merge-tree` 只看得见已提交的东西）。
所以正常情况下，**冲突根本不会走到「stash 完再回滚」那一步**。回滚逻辑还留着，但它现在是保险丝，不是主路径。

**二、同一个阻塞不重复空转。** 卡住时把「当时分支 HEAD + 主分支 HEAD」这一对记进 state。下次两边都没变，就直接复用上次结论，报告改成「还是上次那个阻塞，已经卡了 N 天」，不再重算。两边任意一边动了就重新判断。合并成功会把记录清掉。

**三、卡太久要提高音量。** 超过 `blockedEscalateDays`（默认 7 天），钩子注入的上下文里会多一段硬指令，要求你**把这件事放在第一句**、说清卡了多久卡在哪、并直接问用户要不要现在处理。同一个仓也会出现在 `/repo-inbox` 的 `blockedRepos` 里。看到这种升级提示时不要一笔带过——冲突拖得越久越难解，这正是它该被当回事的原因。

## 需要知道的两件事

- **主分支不能盲目自动探测。** 有的仓在 GitHub 上把默认分支设成了一个早就并进主线、已经落后几十个提交的分支——这种情况下 `gh repo view` 和 `origin/HEAD` 返回的都是错的值，而且错得很安静。所以 config 里的 `repos.<仓名>.defaultBranch` 覆盖优先级最高，遇到一个就往那里加一条。
- **脚本不切分支。** 用 `git fetch origin <主分支>:<主分支>` 直接快进本地主分支，全程待在你当前的分支上，所以工作区脏也不影响更新主分支。
