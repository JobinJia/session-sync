---
name: repo-inbox
description: 'Check whether anyone replied to or reviewed the PRs, issues, and discussions I opened on GitHub, and pull the actual content down. Use when the user asks 有没有人回我 / 有人回复我的 PR 吗 / 看看有没有人评审 / 我的 issue 有人回吗 / 谁给我留言了 / 有没有新评论 / check my PRs / any reviews on my PRs, or mentions "/repo-inbox". Scoped to the repo the session is currently in — running it inside a project reports only that project. Outside a git repo it falls back to the whole org; --org forces the org-wide view. Reports only what is new since the last check, ranked by how urgently it needs a response, plus failing CI and any branch stuck unmerged.'
allowed-tools: Bash, Read
---

# repo-inbox — 有没有人回我

查 GitHub 上**我发起的** PR / issue / discussion 有没有人回复、有没有人评审，把内容拉下来讲给用户听。

**默认只查当前所在的这个仓库**——在哪个项目里用，就只出那个项目的东西。仓库是从 `origin` 的 remote 地址推出来的（`owner/name`），不是靠配置猜的，所以跨组织也不会漏——多仓工作区里常有个别仓属于另一个组织，把组织名写死的查法会把它们整个漏掉，而且不会报错。

当前目录不是 git 仓库时（比如多仓工作区的根目录），退回查整个组织，并在输出的 `scopeReason` 里说明。

脚本：`~/.claude/skills/repo-inbox/scripts/inbox.sh`（输出 JSON）
配置：`~/.claude/session-init/config.json` 的 `inbox` 段
已读状态：`~/.claude/session-init/state/inbox-seen.json`

## 怎么用

| 用户说什么 | 你跑什么 |
| --- | --- |
| 有没有人回我 / 看下有没有新回复 | `inbox.sh`（当前仓 + 增量：只报上次查看之后的新内容，跑完自动标记已读） |
| 全部看一遍 / 之前的也翻出来 | `inbox.sh --all`（仍是当前仓，只是不受已读状态限制，也不改已读） |
| 所有项目一起看 / 我名下全部的 | `inbox.sh --org`（强制整个组织） |
| 看某个别的仓 | `inbox.sh --repo <仓名>`（owner 用配置里的组织补全，也可以直接写 `owner/name`） |
| 我先看看但别标已读 | `inbox.sh --no-mark` |

输出里的 `scope` / `scopeReason` 会说明这次查的到底是哪个范围、为什么是这个范围。**汇报时先说清范围**——用户得知道你看的是「这个项目」还是「全部」，否则「没人回你」这句话会有歧义。

## 怎么汇报

输出是 JSON，**不要贴 JSON**。按下面的优先级用中文讲：

1. **🔴 需要我回应的**——`review:CHANGES_REQUESTED`、评审里提了具体问题、`review-comment`（代码行内评论，`ctx` 字段是 `文件:行号`）。
   把评论**原文**给用户看（这是他要的「把内容拉下来」），并说清对方在质疑什么、涉及哪个文件哪一行。
2. **🟡 有新回复但只是讨论**——普通 comment、`review:APPROVED`、discussion 的回复。摘要 + 原文。
3. **🔧 长期合不上主分支的仓**——输出里的 `blockedRepos`。这是 session-sync 记下来的：某个仓的开发分支合不进主分支，卡了 `stuckDays` 天。
   卡 7 天以上的要单独点出来，说清是哪个仓、哪个分支、卡在哪几个文件（`files`）、什么原因（`kind`：`merge-conflict` 是真冲突，`dirty-overlap` 是没提交的改动挡着）。
   `kind` 是 `dirty-overlap` 的话，出路很简单：把手上改动提交或 stash 掉就能合，值得当场提醒。
4. **⚙️ CI 挂了的 open PR**——`ci` 字段是 `FAILURE`/`ERROR` 的。只报还开着的 PR，已合并/已关闭的红灯是噪音。
5. **⏳ 还开着但没人理的**——`openNoNewReplies`。这些没有新回复，所以不算「有人回我」，但它们**还没了结**，该让用户心里有数。
   一句话带过就行：几个、分别是什么、开了多久（`openDays`）、多久没动静（`quietDays`）。
   `everAnswered: false` 且 `quietDays` 大的要单独点名——**从头到尾没人理过**的东西才是真正会烂掉的那种。
   `draft: true` 的降一档说，草稿没人评审是正常的。

每条都带上 `url`，用户要看细节时直接点。

讲完之后主动问一句要不要现在处理其中某条——很多评审意见是可以立刻改的。

## 注意

- **跑完 `inbox.sh`（不带 `--all`）就等于标记已读了**，同一批内容下次不会再报。所以务必在这一次就把内容讲清楚，别让用户重跑一遍才发现没了。用户说「先别标已读」时加 `--no-mark`。
- **筛选标准是状态，不是时间。** 还开着的 PR / issue 一律全查，开了半年也照查不误——自己开的东西没关掉就是还没了结。
  只有**已关闭 / 已合并**的才卡一道时间窗（`closedLookbackDays`，默认 30 天），因为别人常在合并后才补评审意见，
  但没必要把三年前的老账全翻出来。这两类的新回复都会报。
- 输出里的 `truncated` 不为空时，说明某一类超过了单次 100 条的上限、**有内容没取到**。
  必须如实告诉用户哪一类被截断了，别让他以为看全了。
- 用户要在浏览器里打开某条时，按全局规则走带插件的 Chrome：
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --profile-directory="Default" "<url>"`，别用 Playwright。
- config 的 `inbox` 段：`org`（`--org` 和跨仓补全用的组织名）、`includeCI`、`closedLookbackDays`（已关闭的回溯几天，默认 30；开着的不受限制）。默认范围跟着当前仓走，不需要配。
