# Contributing to Ainto

Thanks for your interest in contributing!

## Building

See the [README](README.md). Quick loop: `./build.sh` then `make run`.
Use `make app` to build the `.app` bundle when testing bundle-only features
(Sparkle updates, Launch at Login, menubar icon).

## Pull requests

You don't need to open an issue first — direct contributions are welcome. For
larger changes, opening an issue to discuss first is appreciated.

- Branch off `main`.
- PR title — imperative, no trailing period:
  - Prefix with `GH-<issue>:` when the PR addresses a GitHub issue.
    e.g. `GH-1: Add a master switch to hide all AI features`.
  - Otherwise just describe the change, e.g. `Show Finder in search results`.
    You may prefix trivial changes (docs, typos, cleanups) with `MINOR:`.
- When there's an issue, reference it with `Refs #<issue>`. Issues are closed
  when the fix ships in a release, not on merge.
- Keep PRs focused; one logical change each. We squash on merge.

## Commit messages

- Imperative, sentence case, **no** `feat:` / `fix:` prefix.
  e.g. `Fix UI freeze when previewing large clipboard text`.
- Describe what changed and why, not the tooling used to make it.
- Version bumps are always `Bump version to X.Y.Z`.

## Releases & versioning

Four files must stay in sync, or CI blocks the release. Bump them with the
helper rather than by hand:

```bash
./Scripts/ci/bump-version.sh X.Y.Z
```

Releases are cut by maintainers — pushing a `vX.Y.Z` tag triggers the workflow.
