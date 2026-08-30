---
name: field-journal
description: "Use when starting a binary-analysis case in this repo, to look up prior work on the same target family or toolchain; and when finishing one — target understood, patch produced, flag captured, or analysis abandoned. Trigger on 'write a field journal', 'log this case', 'record what we learned', 'lessons learned', 'check past experience', 'have we hit this before', 'update the journal', or at the end of any completed idasql / IDA / r2 / angr / APK / Java / Delphi analysis in this repo."
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
solved twice. The write half records what the case proved — as an entry, and
as concrete recommendations against the repo's own configuration.

This skill writes exactly two paths: the new entry, and `_index.md`. Every
other surface it names, it only recommends. The user applies those.

Both halves are required. An entry that records nothing about the toolchain
produces a diary rather than a system that improves — but a recommendation is
where this skill stops.

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
4. Write the evolution actions below into the entry as recommendations. Do not
   apply them.
5. Update `_index.md`. This step is mandatory; an entry that is not indexed is
   invisible to the read half and might as well not exist.
6. List the recommendations in your reply to the user, one line each, and stop
   there.

## Evolution actions — recommend, never apply

After writing the entry, ask what this case proved about the repo itself. Put
each belief in the entry as a recommendation. Do not edit the file that holds
the belief.

**Paths this skill writes**, needing no permission — they are the journal's
own storage:

- `entries/YYYY-MM-DD_<slug>.md`
- `_index.md`

**Paths this skill only recommends.** Edit one of these only when the user, in
this session, tells you to after seeing the recommendation. Their own words —
not your reading of what the case implies, not silence:

| Surface | Recommend when |
|---------|----------------|
| `CLAUDE.md` → "Installed tool catalog" | A tool was used that is not listed, or a listed tool turned out to be missing, renamed, or a different version |
| `CLAUDE.md` → container conventions | An invocation trap was discovered — a required env var, a flag that must be passed, a conflict between concurrent runs |
| `.claude/skills/<name>/SKILL.md` | Another skill's documented procedure was wrong, missing a step, or sent the analysis down a dead end |
| `.claude/skills/<name>/references/*.md` | Knowledge found by web search or by reading source that will be needed again |
| `Dockerfile` | A tool had to be installed by hand and belongs in the image |
| `tools/scripts/*` | A project script failed or needed a workaround |

`CLAUDE.md` appears twice deliberately. It is the only file loaded in every
session, which makes it both the highest-leverage surface here and the one
that most needs a human to approve it: a line changed there alters every
future session, on every target, without anyone consulting the journal. The
two rows catch different discoveries — *a new tool exists* versus *an existing
tool is being invoked wrongly*. The second kind (`MSYS_NO_PATHCONV=1`, "only
one `--http` server per database") costs hours to rediscover, which is why it
is worth writing up carefully and worth asking before installing.

### Shape of a recommendation

Each one has four parts, in this order:

1. **Surface** — the exact path, and the heading inside it.
2. **Change** — the literal text to add or replace, in a fenced block, ready
   to paste. Not a description of the change.
3. **Evidence** — the execution-chain step in *this* case that proved it.
4. **Cost of skipping** — what the next session re-pays without it.

A recommendation without part 2 is a wish. Write the paste-ready text or drop
the recommendation.

Recommend only what the case genuinely revealed. An entry with no
recommendations is a normal outcome; inventing one to fill the section is
worse than leaving it empty.

### Rationalizations

| Excuse | Reality |
|--------|---------|
| "It is one line in the tool catalog" | One line in the always-loaded file changes every future session. Size is not the axis; blast radius is. |
| "The user asked me to update the journal" | That authorizes the entry and `_index.md`. Nothing else. |
| "This skill used to say CLAUDE.md is the highest-leverage surface" | Leverage is the reason to ask, not the reason to skip asking. |
| "I will apply it and mention it in my summary" | Telling someone after the write is not permission. Permission comes first. |
| "The other skill's procedure is plainly broken; leaving it is worse" | Recommend it with the corrected text. Applying it costs the user one word. |
| "They approved this same edit on the previous case" | Approval does not carry across cases. Ask again. |
| "It is a skill file, part of my own configuration" | Everything under `.claude/` is the user's repo. |
| "The change is obviously correct" | Then it will be approved in one word. Ask. |

### Red flags — stop

- About to call `Edit` or `Write` on any path that is not the new entry or
  `_index.md`
- About to write "I also updated…", "I went ahead and…", "while I was there…"
- Reasoning that a change is too small to be worth raising
- Justifying an edit by how valuable the change is, rather than by an
  instruction the user actually gave

**All of these mean: revert what you wrote, and move the change into the
entry's recommendation list.**

### When the user approves

They may approve some recommendations and not others. Apply exactly the ones
named. Applying a neighbouring recommendation because it was "in the same
list" is the same violation as applying it unasked. After applying, set that
recommendation's **Status** in the entry to `applied YYYY-MM-DD`.

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
