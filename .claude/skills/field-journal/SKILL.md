---
name: field-journal
description: "Record and reuse reverse-engineering case experience for this repo, and evolve the repo's own tool catalog and skills from what each case revealed. Use when finishing a binary-analysis case (target understood, patch produced, flag captured, analysis abandoned) to write a journal entry and carry out its evolution actions; and when starting a case to look up prior work on the same target type or toolchain. Trigger on 'write a field journal', 'log this case', 'record what we learned', 'lessons learned', 'check past experience', 'have we hit this before', 'update the journal', or at the end of any completed idasql / IDA / r2 / angr / APK / Java / Delphi analysis in this repo."
metadata:
  argument-hint: "[read | write] [case-slug]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

## Purpose

A closed loop with two halves. The read half stops the same problem being
solved twice. The write half mutates this repo's own configuration so the
next session inherits the lesson without having to look anything up.

Both halves are required. Writing entries without carrying out the evolution
actions produces a diary, not a system that improves.

## Layout

```
.claude/skills/field-journal/
  SKILL.md       # this file
  _template.md   # entry schema — copy it, never edit an entry into a new shape
  _index.md      # inverted index; the only file the read half consults first
  entries/       # YYYY-MM-DD_<slug>.md
```

## Read half — before starting a case

1. Read `_index.md`. It is small by design; read the whole thing.
2. Look for a prior case matching on **any** axis: same category, same target
   family, same tool, same technique. A match on tooling is often more useful
   than a match on target.
3. If a candidate exists, read that entry — in particular its **Pitfalls** and
   **Toolchain findings** sections, which are where the recoverable time is.
4. Reuse the verified approach. If the prior approach does not apply, note why
   in the new entry; that negative result is itself worth recording.
5. If `_index.md` has no relevant entry, proceed normally and say so briefly.

## Write half — after finishing a case

A case is finishable in any of these states: target understood, patch
produced, flag captured, or analysis abandoned. **Blocked and abandoned cases
are worth writing** — they record which paths do not work, which is the
information most expensive to rediscover.

1. Choose a slug: `entries/YYYY-MM-DD_<short-kebab-slug>.md`. Date the day the
   work happened, not the day of writing.
2. Copy `_template.md` and fill its frontmatter. Keep `tools` and `techniques`
   to terms already used in `_index.md` where one fits; introduce a new term
   only when nothing existing matches.
3. Fill the body. The **Execution chain** must include dead ends and reverted
   attempts — a clean narrative of only the winning path discards most of the
   entry's value.
4. Carry out the evolution actions below and tick what you actually did.
5. Update `_index.md`. This step is mandatory; an entry that is not indexed is
   invisible to the read half and might as well not exist.

## Evolution actions

After writing the entry, ask what this case proved about the repo itself, and
change the file that holds that belief. Tick only what the case genuinely
revealed — ticking everything by reflex is as useless as ticking nothing.

| Surface | Apply when |
|---------|-----------|
| `CLAUDE.md` → "Installed tool catalog" | A tool was used that is not listed, or a listed tool turned out to be missing, renamed, or a different version |
| `CLAUDE.md` → container conventions | An invocation trap was discovered — a required env var, a flag that must be passed, a conflict between concurrent runs |
| `.claude/skills/<name>/SKILL.md` | Another skill's documented procedure was wrong, missing a step, or sent the analysis down a dead end |
| `.claude/skills/<name>/references/*.md` | Knowledge found by web search or by reading source that will be needed again |
| `Dockerfile` | A tool had to be installed by hand and belongs in the image |
| `tools/scripts/*` | A project script failed or needed a workaround |
| `_index.md` | Always |

`CLAUDE.md` appears twice deliberately. It is the only file loaded in every
session, which makes it the highest-leverage surface here: a line changed
there alters every future session without anyone consulting the journal.
The two rows catch different discoveries — *a new tool exists* versus *an
existing tool is being invoked wrongly*. The second kind (`MSYS_NO_PATHCONV=1`,
"only one `--http` server per database") costs hours to rediscover.

When an evolution action would be large or would change behaviour beyond the
current case, describe it in the entry and raise it with the user rather than
applying it silently.

## Index update

`_index.md` carries four headings: Stats, By category, By tool, By technique.
Sub-headings exist only where an entry uses them — create the sub-heading on
first use, and do not pre-create empty ones.

For each new entry:

1. Add a line under the matching **By category** sub-heading:
   `- [YYYY-MM-DD title](entries/<file>.md) — <one-clause hook>`
2. Add the file under each of its `tools` and `techniques` sub-headings.
3. Update **Stats**: entry count and last-updated date.

## Before committing

This repo is public (`github.com/neoz/neo-rev-lab`) and `.claude/skills/` is
tracked, so entries are pushed. There is no automated leak scan. Replace real
credentials, tokens, customer hostnames, and licence keys with placeholders
(`{token}`, `{target_domain}`, `{licence_key}`) and keep the surrounding
structure so the entry stays reusable.
