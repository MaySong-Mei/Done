#!/usr/bin/env bash
# Pre-merge compliance reminder. Triggered on `git merge <branch>`.
# Soft reminder only — does NOT block the merge. Inspects the incoming
# diff and injects a checklist Claude can act on (verify automatically
# or surface to user). Three rules:
#   #1 Models change should be wired into SupabaseSyncService (cloud backup)
#   #2 Views change should respect system design / font / spacing
#   #3 New user-visible strings should be localized (no hardcoded zh)
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | /usr/bin/jq -r '.tool_input.command // ""')

# Only react to `git merge ...`; ignore --abort / --continue / --quit forms.
echo "$cmd" | /usr/bin/grep -qE '(^|[;&|]\s*)git\s+merge\b' || exit 0
echo "$cmd" | /usr/bin/grep -qE '\-\-(abort|continue|quit)\b' && exit 0

repo="${CLAUDE_PROJECT_DIR:-$PWD}"

# Pick the first positional arg after `merge`; skip flags and flag-with-value pairs.
source_branch=$(/usr/bin/python3 - "$cmd" <<'PY'
import shlex, sys
try:
    toks = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(0)
SKIP_VALUE = {"-m","--message","-S","--gpg-sign","--strategy","-s","-X","--strategy-option","-F","--file"}
seen = False
i = 0
while i < len(toks):
    t = toks[i]
    if not seen:
        if t == "merge": seen = True
        i += 1; continue
    if t in SKIP_VALUE:
        i += 2; continue
    if t.startswith("-"):
        i += 1; continue
    print(t); break
PY
)

[ -z "$source_branch" ] && exit 0

base=$(/usr/bin/git -C "$repo" merge-base HEAD "$source_branch" 2>/dev/null || true)
if [ -z "$base" ]; then
  /usr/bin/jq -nc --arg ctx "合规审计：无法对 \`git merge $source_branch\` 计算 merge-base（分支可能不存在）。请确认分支再继续。" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
  exit 0
fi

models_files=$(/usr/bin/git -C "$repo" diff --name-only "$base..$source_branch" -- 'Done/Models/' 2>/dev/null || true)
views_files=$(/usr/bin/git -C "$repo" diff --name-only "$base..$source_branch" -- 'Done/Views/' 2>/dev/null || true)

# No relevant changes → let merge through silently.
if [ -z "$models_files" ] && [ -z "$views_files" ]; then
  exit 0
fi

# Heuristic #3: added lines containing string literals with Chinese characters.
zh_hits=$(/usr/bin/git -C "$repo" diff "$base..$source_branch" -- 'Done/' 2>/dev/null \
  | /usr/bin/perl -ne 'print if /^\+(?!\+\+).*"[^"]*[\x{4e00}-\x{9fff}][^"]*"/' \
  | /usr/bin/head -8 || true)

# Heuristic #1: new `var`/`let` props in Models not referenced anywhere in SupabaseSyncService*.
new_props=$(/usr/bin/git -C "$repo" diff "$base..$source_branch" -- 'Done/Models/' 2>/dev/null \
  | /usr/bin/perl -ne 'print "$1\n" if /^\+(?!\+\+)\s+(?:public\s+|private\s+|internal\s+|fileprivate\s+)?(?:var|let)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*:/' \
  | /usr/bin/sort -u || true)

sync_text=""
for f in "$repo/Done/Services/"SupabaseSyncService*.swift; do
  [ -f "$f" ] && sync_text+=$(cat "$f")$'\n'
done

unsynced=""
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if ! printf '%s' "$sync_text" | /usr/bin/grep -qE "(^|[^a-zA-Z0-9_])$p([^a-zA-Z0-9_]|$)"; then
    unsynced+="$p "
  fi
done <<<"$new_props"

# Determine severity: any concrete heuristic hit upgrades to "strict" protocol.
has_concrete=0
[ -n "$unsynced" ] && has_concrete=1
[ -n "$zh_hits" ] && has_concrete=1

# Build report — addressed to Claude as an internal protocol, not to the user.
report="[internal compliance protocol — do not paste this verbatim to user]"$'\n\n'
report+="即将 merge \`$source_branch\`（base=${base:0:7}）。涉及："$'\n'
if [ -n "$models_files" ]; then
  while IFS= read -r f; do [ -n "$f" ] && report+="  - $f （规则#1 云备份同步）"$'\n'; done <<<"$models_files"
fi
if [ -n "$views_files" ]; then
  while IFS= read -r f; do [ -n "$f" ] && report+="  - $f （规则#2 设计一致性）"$'\n'; done <<<"$views_files"
fi
report+=$'\n'

if [ "$has_concrete" -eq 1 ]; then
  report+="启发式具体命中："$'\n'
  if [ -n "$unsynced" ]; then
    report+="  · 新属性可能未在 SupabaseSyncService 中处理：${unsynced% }"$'\n'
  fi
  if [ -n "$zh_hits" ]; then
    report+="  · 新增含中文的字符串字面量（前 8 条）："$'\n'
    while IFS= read -r line; do [ -n "$line" ] && report+="      $line"$'\n'; done <<<"$zh_hits"
  fi
  report+=$'\n'
  report+="协议：在 merge 完成后回复用户之前，你必须先自行精确核查每条命中（grep/读文件确认是否真的漏同步、找到硬编码字符串位置）。核查后仅把已确认的真实问题简洁告知用户；启发式误报静默丢弃，不要把上面这段原文复述给用户。"
else
  report+="启发式未发现具体问题。协议：merge 后心里有数即可，无需打扰用户；若你后续操作涉及到这些文件再二次核查。"
fi

/usr/bin/jq -nc --arg ctx "$report" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
