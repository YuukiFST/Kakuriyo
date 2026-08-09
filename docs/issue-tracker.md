# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`
- **Read an issue**: `gh issue view <number> --comments`
- **List issues**: `gh issue list --state open`
- **Comment / label / close**: `gh issue comment`, `gh issue edit --add-label`, `gh issue close`

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: linked to the map as a GitHub sub-issue when available; otherwise `Part of #<map>` in the child body and a task list on the map. Labels: `wayfinder:<type>` (`research` / `prototype` / `grilling` / `task`).
- **Blocking**: native issue dependencies when available; else `Blocked by: #<n>, #<n>` in the child body.
- **Frontier**: open children of the map with no open blocker and no assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me`
- **Resolve**: comment the answer, close the issue, append a context pointer to the map's Decisions-so-far.

Local markdown under `.scratch/kakuriyo/issues/` is an **archive** from the pre-GitHub tracker. Live state is GitHub.
