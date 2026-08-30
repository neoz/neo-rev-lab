---
date: YYYY-MM-DD
title:
category:            # reuse a sub-heading from _index.md, or coin one
target:
tools: []            # command names as actually invoked
techniques: []       # reuse sub-headings from _index.md, or coin them
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
     Record the exact invocation, not the tool's name on its own. -->

## Reusable commands / snippets

```text

```

## Recommended evolution actions

<!-- Recommendations only. Writing this entry and updating `_index.md` are the
     only edits this skill makes; the user applies everything below.
     Candidate surfaces: CLAUDE.md "Installed tool catalog" (new or stale
     tool), CLAUDE.md container conventions (invocation trap),
     .claude/skills/<name>/SKILL.md (procedure wrong), .../references/*.md
     (searched knowledge worth keeping), Dockerfile (tool to add to the image),
     tools/scripts/* (script needing a fix).
     If the case revealed nothing, write "None." and delete the block below —
     an invented recommendation is worse than an empty section. -->

### 1. <exact path> -> <heading inside it>

**Change** (paste-ready):

```text

```

- **Evidence:** execution-chain step <n>
- **Cost of skipping:** <what the next session re-pays>
- **Status:** proposed <!-- proposed | applied YYYY-MM-DD | declined -->

## Environment

- Image / container:
- Tool versions: <!-- one line per tool in `tools`, with how it was reached -->
- Target platform:

---

> This repo is public. Do not paste real credentials, tokens, customer
> hostnames, or licence keys into an entry — replace them with `{token}`,
> `{target_domain}`, `{licence_key}` and keep the surrounding structure so the
> entry stays reusable.
