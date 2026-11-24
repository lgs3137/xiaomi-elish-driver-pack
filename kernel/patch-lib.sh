#!/bin/bash
# kernel/patch-lib.sh — 补丁“是否已在树中”的判定（被 build-and-install.sh / compat-check.sh source）
#
# 背景：同一段代码可能被后续补丁或手工改动改写过，导致增量树里出现：
#   - 正向 dry-run 失败（内容已存在）
#   - 反向 dry-run 也失败（上下文/行号已漂移）
# 这时按“补丁新增行是否已在目标文件中”做保守判断：命中率 >= 70% 视为“内容已在树中”，
# 仅打印 INFO，不再报 WARN 误导（真正的缺失补丁命中率通常远低于此）。
#
# 用法：patch_content_present <源码树> <补丁文件>
#   命中：返回 0，并设置 PATCH_PRESENT_STATS="hit/total"
#   未命中/无法判断：返回 1

patch_content_present() {
    local tree=$1 pf=$2 f s total=0 hit=0
    [ -d "$tree" ] && [ -f "$pf" ] || return 1
    while IFS=$'\t' read -r f s; do
        [ -n "$f" ] || continue
        [ -f "$tree/$f" ] || return 1
        total=$((total + 1))
        if grep -Fq -e "$s" "$tree/$f" 2>/dev/null; then
            hit=$((hit + 1))
        fi
    done < <(awk '
        /^\+\+\+ b\// { f = substr($0, 7); next }
        /^\+\+\+ /    { f = ""; next }
        /^\+/ && f != "" {
            s = substr($0, 2)
            sub(/^[ \t]+/, "", s)
            sub(/[ \t]+$/, "", s)
            if (length(s) >= 4) printf "%s\t%s\n", f, s
        }' "$pf" 2>/dev/null)
    [ "$total" -ge 4 ] || return 1
    PATCH_PRESENT_STATS="$hit/$total"
    [ $((hit * 10)) -ge $((total * 7)) ]
}
