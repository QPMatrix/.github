# .github

This is the QPMatrix org profile repo — GitHub renders the public org page
from [`profile/README.md`](profile/README.md).

## Setup (every clone)

```sh
git config core.hooksPath .githooks
```

The gate is `./check`; the pre-commit hook and CI run exactly it
(repo-gates-and-hooks parity rule). Extend `check` as content arrives.
