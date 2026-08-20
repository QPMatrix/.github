# .github

QPMatrix — org profile and community defaults

## Setup (every clone)

```sh
git config core.hooksPath .githooks
```

The gate is `./check`; the pre-commit hook and CI run exactly it
(repo-gates-and-hooks parity rule). Extend `check` as content arrives.
