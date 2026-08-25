#!/usr/bin/env bash
# 把这个项目反复踩到的几类坑变成能自动发现的东西。改完脚本、提交之前都该跑一遍。
# 只用 BSD grep 也认的写法，别依赖 GNU 扩展（macOS 自带的 grep 不一定有 -P）。
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# 排除自己：这个文件必然包含下面那些坏模式的字面量
files=$(find . -name '*.sh' -not -path './.git/*' -not -name 'lint.sh')
fail=0
say() { printf '%-44s %s\n' "$1" "$2"; }
report() { say "$1" "✗"; printf '%s\n' "$2" | sed 's/^/    /'; fail=1; }

# ① bash 3.2（macOS 自带的唯一一个）按字节判断变量名边界：`$var` 后面紧跟非 ASCII
#    会被吞进变量名，set -u 下直接退出 —— 而且常常死在被 2>/dev/null 吞掉的块里，
#    现象是"脚本无声中断、文件只写了一半"。写成 ${var} 就没事。
h=$(grep -n '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' $files 2>/dev/null)
[ -n "$h" ] && report "变量后紧跟非 ASCII（会被吞进变量名）" "$h" \
             || say "变量后紧跟非 ASCII（会被吞进变量名）" "✓"

# ② 全角空格同理（U+3000 的首字节也是非 ASCII）
h=$(grep -n '　' $files 2>/dev/null)
[ -n "$h" ] && report "全角空格" "$h" || say "全角空格" "✓"

# ③ bash 4 才有的内建，macOS 上不存在（注释里提到不算）
h=$(grep -nE '^[^#]*\b(mapfile|readarray)\b' $files 2>/dev/null)
[ -n "$h" ] && report "bash 4 专属内建（macOS 是 3.2）" "$h" \
             || say "bash 4 专属内建（macOS 是 3.2）" "✓"

# ④ jq 里 `X // true` 取布尔是错的：jq 的 // 把 false 当成"不存在"，
#    于是显式写 false 的配置永远关不掉。（`// false` 反过来是安全的，不报。）
h=$(grep -nE '^[^#]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*//[[:space:]]*true' $files 2>/dev/null)
[ -n "$h" ] && report "jq 用 // true 取布尔（false 会被当缺省）" "$h" \
             || say "jq 用 // true 取布尔（false 会被当缺省）" "✓"

# ⑤ 语法
syn=""
for f in $files; do bash -n "$f" 2>/dev/null || syn="$syn$f\n"; done
[ -n "$syn" ] && report "bash -n" "$(printf "$syn")" || say "bash -n 全部脚本" "✓"

echo
[ "$fail" = "0" ] && echo "全部通过" || echo "有问题，见上"
exit $fail
