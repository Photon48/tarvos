# Contributing to Tarvos

Thank you for your interest in contributing! This guide covers everything you need to get started.

---

## Reporting Bugs

Use the [Bug Report](.github/ISSUE_TEMPLATE/bug_report.yml) issue template. Please include:
- A clear description of the problem
- Steps to reproduce
- Expected vs. actual behavior
- Your OS, architecture, and `tarvos --version` output

For security vulnerabilities, see [SECURITY.md](SECURITY.md) — do **not** open a public issue.

---

## Suggesting Features

Use the [Feature Request](.github/ISSUE_TEMPLATE/feature_request.yml) issue template. Describe:
- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

---

## Development Setup

See [DEVELOPER.md](DEVELOPER.md) for full setup instructions. Quick start:

```bash
git clone https://github.com/Photon48/tarvos.git
cd tarvos
# Run smoke tests to verify your environment
bash tests/smoke-test.sh
```

To work on the TUI you'll also need [`bun`](https://bun.sh):

```bash
cd tui && bun install
bun run build:darwin-arm64   # or your platform
```

---

## Pull Request Process

1. **Branch naming:** `feat/<short-description>`, `fix/<short-description>`, `chore/<short-description>`
2. **Commits:** Follow the [Conventional Commits](https://www.conventionalcommits.org/) format (see examples below)
3. **Tests:** Run `bash tests/smoke-test.sh` — all 19 tests must pass
4. **No hardcoded paths:** Do not commit paths like `/Users/<name>/...` — use generic placeholders
5. **TUI changes:** Build locally and verify the binary works before submitting
6. Open a PR against `main` — CI will run smoke tests automatically

### Commit message examples

```
feat: add session tagging support
fix(tui): handle missing summary file gracefully
chore(deps): bump bun from 1.1.0 to 1.2.0
docs: clarify worktree cleanup behavior
```

---

## Code Style

### Bash (`tarvos.sh`, `lib/*.sh`, `install.sh`)
- Use `shellcheck`-compatible idioms
- Quote all variable expansions: `"$var"` not `$var`
- Use `local` for all function-local variables
- Prefer `[[ ... ]]` over `[ ... ]`
- Error messages go to `stderr`: `echo "Error: ..." >&2`

### TypeScript (`tui/src/`)
- Follow the existing patterns in `src/index.tsx`
- Run `bun x tsc --noEmit` to type-check before submitting
- No `any` types without a comment explaining why

---

## Testing Requirements

All PRs must pass the smoke test suite:

```bash
bash tests/smoke-test.sh
```

The tests exercise `init`, `begin`, `stop`, `continue`, `accept`, `reject`, and `forget` against a temporary isolated git repo. No real Claude API calls are made — `claude` is mocked.

If you add new functionality, add a corresponding test in `tests/smoke-test.sh`.

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
