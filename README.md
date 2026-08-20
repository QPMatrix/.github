# .github

This is the QPMatrix org profile repo — GitHub renders the public org page
from [`profile/README.md`](profile/README.md).

The block between `<!-- DYNAMIC:START -->` / `<!-- DYNAMIC:END -->` near
the foot of that page is refreshed automatically by
[`scripts/update-profile.sh`](scripts/update-profile.sh) (aggregate
GitHub API signals only — see the script header for how repo names are
kept out of the output) via the daily
[`update-profile`](.github/workflows/update-profile.yml) workflow.
Everything outside the markers is hand-authored and never touched by
automation.

## Setup (every clone)

```sh
git config core.hooksPath .githooks
```

The gate is `./check`; the pre-commit hook and CI run exactly it
(repo-gates-and-hooks parity rule) — it includes the privacy fixture
test (`scripts/update-profile.test.sh`) that proves the dynamic block
can never leak a repo name. Extend `check` as content arrives.
