#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /path/to/repo [codex_home]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_REPO="$(cd "$1" && pwd)"
TARGET_REPO_SKILL_DIR="$TARGET_REPO/.codex/skills/topic-orchestrator"
TARGET_TOPICS_DIR="$TARGET_REPO/topics"

if [[ ! -d "$TARGET_REPO" ]]; then
  echo "Target repo does not exist: $TARGET_REPO" >&2
  exit 1
fi

if [[ ! -f "$SCRIPT_DIR/codex-home/skills/topic-orchestrator/SKILL.md" ]]; then
  echo "Bundled skill is missing. Run refresh.sh first." >&2
  exit 1
fi

if [[ ! -d "$SCRIPT_DIR/project/topics" ]]; then
  echo "Bundled topics are missing. Run refresh.sh first." >&2
  exit 1
fi

mkdir -p "$TARGET_REPO_SKILL_DIR" "$TARGET_TOPICS_DIR"
cp "$SCRIPT_DIR/codex-home/skills/topic-orchestrator/SKILL.md" "$TARGET_REPO_SKILL_DIR/SKILL.md"
cp -R "$SCRIPT_DIR/project/topics/." "$TARGET_TOPICS_DIR/"

if [[ $# -eq 2 ]]; then
  TARGET_CODEX_HOME="$2"
  TARGET_GLOBAL_SKILL_DIR="$TARGET_CODEX_HOME/skills/topic-orchestrator"
  mkdir -p "$TARGET_GLOBAL_SKILL_DIR"
  cp "$SCRIPT_DIR/codex-home/skills/topic-orchestrator/SKILL.md" "$TARGET_GLOBAL_SKILL_DIR/SKILL.md"
  echo "Installed topics into $TARGET_TOPICS_DIR"
  echo "Installed repo-local skill into $TARGET_REPO_SKILL_DIR"
  echo "Installed global skill into $TARGET_GLOBAL_SKILL_DIR"
else
  echo "Installed topics into $TARGET_TOPICS_DIR"
  echo "Installed repo-local skill into $TARGET_REPO_SKILL_DIR"
fi
