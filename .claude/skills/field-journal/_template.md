---
date: YYYY-MM-DD
title:
category:            # pe-delphi | apk | java | native-elf | firmware | ctf | toolchain | other
target:
tools: []            # idasql, r2, angr, jadx, apktool, delphi-reverser, ...
techniques: []       # vmt-recovery, string-scan, ssl-unpinning, ...
outcome:             # solved | partial | blocked
---

# <title>

## Goal

<!-- One line: what were we trying to find out or change? -->

## Execution chain

<!-- The full sequence, including dead ends and reverted attempts.
     A tidy summary of only the winning path is worth far less — the dead
     ends are what stop the next session walking down them again. -->

1.
2.
3.

## Pitfalls

| Problem | Cause | Fix | Time lost |
|---------|-------|-----|-----------|
|         |       |     |           |

## Toolchain findings

<!-- Which tools worked, which had traps, version incompatibilities.
     Record the exact invocation, not "used r2". -->

## Reusable commands / snippets

```text

```

## Evolution actions

<!-- Tick only what this case actually revealed. `_index.md` is always ticked. -->

- [ ] CLAUDE.md -> "Installed tool catalog"    (new tool, or catalog now stale)
- [ ] CLAUDE.md -> container conventions       (newly discovered invocation trap)
- [ ] .claude/skills/<name>/SKILL.md           (procedure wrong or missing a step)
- [ ] .claude/skills/<name>/references/*.md    (searched knowledge worth keeping)
- [ ] Dockerfile                               (tool to add to the image)
- [ ] tools/scripts/*                          (script needing a fix)
- [ ] _index.md                                (MANDATORY)
- [ ] No update needed

## Environment

- Image / container:
- IDA / idasql:
- Other tool versions:
- Target platform:

---

> This repo is public. Do not paste real credentials, tokens, customer
> hostnames, or licence keys into an entry — replace them with `{token}`,
> `{target_domain}`, `{licence_key}` and keep the surrounding structure so the
> entry stays reusable.
