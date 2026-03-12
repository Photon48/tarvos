# Security Policy

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Email: rishu.goyal@outlook.com.au (or open a private GitHub security advisory)

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact

We aim to respond within 72 hours and resolve confirmed issues within 14 days.

## Scope

- `tarvos.sh` and `lib/` — shell orchestration logic
- `install.sh` — installer script
- `tui/` — terminal UI binary

## Notes

The `--dangerously-skip-permissions` flag passed to `claude` is intentional and documented. Tarvos runs agents in isolated git worktrees to contain changes. Users should only run Tarvos on codebases they own.
