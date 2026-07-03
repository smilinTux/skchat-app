# Contributing to skchat-app

Thanks for helping build the sovereign SKChat client. This repo follows the
SKWorld [`sk-standards`](https://github.com/smilinTux/sk-standards) doc + testing
conventions. Read [`SOP.md`](./SOP.md) first — it explains the architecture,
build, and the "start here" files.

## Branch model

- `main` is the integration branch. **Do not commit directly to `main`.**
- Branch per unit of work, prefixed by type:
  - `feat/<short-name>` — new capability
  - `fix/<short-name>` — bug fix
  - `docs/<short-name>` — docs/SOP only
  - `integrate/<name>` — integration/rebase branches
- Rebase onto the latest `main` before opening a PR; keep history readable.
- Isolate parallel work with `git worktree` (the codebase and its `sk_pqc`
  path-override make sibling checkouts the safe pattern — see `SOP.md` §3).

## Quality gate (must pass before merge)

```bash
flutter pub get
flutter analyze     # must be clean (info-level lints tolerated)
flutter test        # must pass
```

A PR is not mergeable until **`flutter analyze` is clean and `flutter test` is
green**. Don't claim a build/feature works without having run these — evidence
before assertions (see `sk-standards` honest-claims gate).

## Commit conventions

- Use clear, imperative subject lines (`fix(livekit): wire _dataCtl receive`).
- Keep unrelated changes in separate commits/PRs.
- **Every commit ends with the Co-Authored-By trailer** identifying the agent
  that authored it, e.g.:

  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

- No secrets, tokens, or private key material in commits — ever. The app holds
  key material only at runtime in the platform keystore (see `SECURITY.md`).

## Honest-claims rules

Per `sk-standards`, no doc, README, CHANGELOG, or comment may assert a state that
isn't reproducible from Build/Test/Deploy, and no crypto claim may exceed what the
code actually does. **Forbidden words:** "quantum-proof", "quantum-safe",
"unbreakable", and any FIPS/suite label the code doesn't implement. Scope crypto
claims to the exact surface: the call-media leg is DTLS-SRTP (classical); PQ
protection is the `sk_pqc` DM KEM only.

## Reporting security issues

Do **not** open a public issue for a vulnerability — follow
[`SECURITY.md`](./SECURITY.md).

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).
