#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_SKILL="$HOME/.codex/skills/topic-orchestrator/SKILL.md"
BUNDLE_SKILL_DIR="$SCRIPT_DIR/codex-home/skills/topic-orchestrator"
BUNDLE_PROJECT_DIR="$SCRIPT_DIR/project"
BUNDLE_TOPICS_DIR="$BUNDLE_PROJECT_DIR/topics"

if [[ ! -f "$SOURCE_SKILL" ]]; then
  echo "Missing source skill: $SOURCE_SKILL" >&2
  exit 1
fi

if [[ ! -d "$REPO_ROOT/topics" ]]; then
  echo "Missing source topics directory: $REPO_ROOT/topics" >&2
  exit 1
fi

mkdir -p "$BUNDLE_SKILL_DIR" "$BUNDLE_PROJECT_DIR"
rm -rf "$BUNDLE_TOPICS_DIR"
mkdir -p "$BUNDLE_TOPICS_DIR"

cp "$SOURCE_SKILL" "$BUNDLE_SKILL_DIR/SKILL.md"
cp -R "$REPO_ROOT/topics/." "$BUNDLE_TOPICS_DIR/"

echo "Refreshed topic system bundle in $SCRIPT_DIR"
