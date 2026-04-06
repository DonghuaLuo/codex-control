# Contributing

Thanks for wanting to improve `codex-control`.

This repository is small on purpose. Try to keep changes direct, testable, and easy to reason about.

## Development Setup

- Windows PowerShell 5.1+ or PowerShell 7
- `git`
- `codex` on PATH if you want to test the real wrapper flow

Clone the repo:

```powershell
git clone https://github.com/DonghuaLuo/codex-control.git
cd codex-control
```

## Local Test Commands

Run the built-in smoke coverage:

```powershell
.\cc.ps1 self-test
.\cc.ps1 plan-self-test
.\cc.ps1 wrapper-self-test
.\cc.ps1 orchestration-self-test
```

What these cover:

- `self-test`: run state transitions, failure reopen, blocker handling, finish gate
- `plan-self-test`: planner integration and fallback behavior
- `wrapper-self-test`: gated Codex wrapper loop behavior
- `orchestration-self-test`: assignments, outputs, resume flow

## Changing Verification Profiles

The profiles in `profiles/` are examples and starter configs.

If you add a new example profile:

- keep it generic
- avoid project-private paths
- avoid secrets or machine-specific assumptions

## Changing Templates

Task templates live in `templates/`.

Good templates are:

- execution-oriented
- small enough to verify
- reusable outside one private codebase

If a template is tied to one product, rename it as an example template and make that clear in the filename.

## Pull Request Notes

When sending a change:

- explain what user-visible behavior changed
- mention whether any run-state or gate semantics changed
- include the test commands you ran
- update `README.md`, `README.zh-CN.md`, or `CHANGELOG.md` if the behavior changed

## Release Notes

Public releases should update:

- `CHANGELOG.md`
- `README.md` if setup or usage changed
- `README.zh-CN.md` if the Chinese guide is now stale
