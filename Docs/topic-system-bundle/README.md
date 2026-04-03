# Topic System Bundle

This folder packages the topic workflow into a portable bundle for another machine.

## What Is Included

- `codex-home/skills/topic-orchestrator/SKILL.md`
- `project/topics/`
- `refresh.sh`
- `install.sh`

The bundle is a copy of the live files. Your current project still uses the root-level `topics/` directory, so existing local workflows do not change.

## Refresh The Bundle

Run this on the source machine after updating the skill or any topic file:

```bash
./Docs/topic-system-bundle/refresh.sh
```

It copies:

- `~/.codex/skills/topic-orchestrator/SKILL.md` into the bundle
- `./topics/` into the bundle

## Install On Another Machine

Copy this whole folder to the target machine, then run:

```bash
./install.sh /path/to/repo
```

That installs:

- `project/topics/` into `/path/to/repo/topics/`
- the skill into `/path/to/repo/.codex/skills/topic-orchestrator/`

If you also want a global Codex skill install on the target machine:

```bash
./install.sh /path/to/repo ~/.codex
```

That additionally installs:

- `codex-home/skills/topic-orchestrator/SKILL.md` into `~/.codex/skills/topic-orchestrator/`

## Notes

- `install.sh` overwrites files with the same names in the target locations.
- Files that were deleted from the source bundle are not automatically deleted from the target.
- If you later want to make the bundled path the live path inside this repo, that is a separate migration because the skill currently expects `topics/` at the repository root.
