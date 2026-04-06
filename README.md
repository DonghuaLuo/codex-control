# codex-control

![License](https://img.shields.io/github/license/DonghuaLuo/codex-control)
![Release](https://img.shields.io/github/v/release/DonghuaLuo/codex-control)
![PowerShell](https://img.shields.io/badge/runtime-PowerShell-5391FE)

`codex-control` is a gated control loop for Codex CLI.

It turns one-shot agent execution into a persistent run with planning, verification, reopen-on-failure, resume-by-task-name, and finish-gate enforcement.

中文说明见 [README.zh-CN.md](./README.zh-CN.md)。

## Why It Exists

Raw CLI agent sessions often stop in the worst possible place:

- code changed, but not verified
- verification failed, but nobody reopened the work
- there is no durable run history to resume from
- the task "feels done", but the repo is still not actually green

`codex-control` fixes that by forcing a loop:

`plan -> implement -> verify -> fix -> reverify -> finish-gate`

No green gate, no finish. That's the whole game.

## Core Features

- Persistent run state with task records, assignments, failures, artifacts, and agent outputs
- Optional automatic task planning before execution
- Verification profiles that define the real checks required for completion
- Automatic reopening when required checks fail
- External blocker tracking and unblock flow
- Resume-by-task-name workflow for long-running workstreams
- Self-tests for planner flow, wrapper flow, orchestration flow, and gate logic

## How It Works

Every run has a state file and a finite-state workflow.

```text
PLANNING
  -> IMPLEMENTING
  -> VERIFYING
  -> FIXING
  -> REVERIFYING
  -> READY_TO_FINISH
  -> FINISHED
```

The finish gate only passes when all of these are true:

- all required tasks are done
- all required tasks are marked verified
- all required checks pass
- no open failures remain
- no external blockers remain
- run status is `READY_TO_FINISH` or `FINISHED`

## Repository Layout

```text
.
├─ cc.ps1
├─ cc.cmd
├─ profiles/
├─ schemas/
├─ scripts/
├─ templates/
├─ CHANGELOG.md
├─ CONTRIBUTING.md
├─ README.md
└─ README.zh-CN.md
```

Runtime data is intentionally excluded from git:

- `runs/`
- `generated-tasks/`
- `active-run.json`
- `task-registry.json`

## Prerequisites

- Windows PowerShell 5.1+ or PowerShell 7
- `codex` available on PATH
- optional: `rtk`, if you want to wrap Codex calls with RTK

## Repository Root Resolution

`codex-control` works in two layouts:

1. standalone repository
2. subdirectory inside another repository

Default behavior:

- if the `codex-control` directory itself contains `.git`, it is treated as the target repo root
- otherwise, its parent directory is treated as the target repo root

You can override this explicitly:

```powershell
$env:CODEX_CONTROL_REPO_ROOT = "D:\path\to\your-repo"
```

## Quick Start

### 1. Clone or copy it into your workflow

You can use `codex-control` as its own repository or copy it into an existing project.

### 2. Create a real verification profile

The default profile deliberately fails until you replace it with real checks.

Starter files:

- [`profiles/default.json`](./profiles/default.json)
- [`profiles/default-gated.json`](./profiles/default-gated.json)
- [`profiles/node-rust-monorepo.example.json`](./profiles/node-rust-monorepo.example.json)

Example:

```powershell
Copy-Item .\profiles\node-rust-monorepo.example.json .\profiles\my-project.json
```

Then edit the `workdir` and `command` fields to match your real repository.

### 3. Start a gated run

```powershell
.\cc.ps1 run `
  -TaskName "fix-plugin-host" `
  -Objective "Repair plugin host parity and close the verification gap" `
  -Prompt "Continue until the verification profile passes." `
  -Profile ".\profiles\my-project.json" `
  -Force
```

### 4. Inspect progress

```powershell
.\cc.ps1 status
.\cc.ps1 tasks
.\cc.ps1 assignments
.\cc.ps1 outputs
```

### 5. Resume the same workstream later

```powershell
.\cc.ps1 resume `
  -TaskName "fix-plugin-host" `
  -Objective "Continue the previous workstream" `
  -Prompt "Resume from the last run and keep going until the gate passes." `
  -Profile ".\profiles\my-project.json" `
  -Force
```

## Main Commands

### Run

```powershell
.\cc.ps1 run `
  -TaskName "your-task-name" `
  -Objective "your objective" `
  -Prompt "your implementation instructions" `
  -Profile ".\profiles\my-project.json" `
  -Force
```

### Plan only

```powershell
.\cc.ps1 plan `
  -Objective "your objective" `
  -Prompt "Analyze this request and split it into execution-ready tasks."
```

### Status

```powershell
.\cc.ps1 status
.\cc.ps1 status -Detailed
```

### Task history

```powershell
.\cc.ps1 task-history -TaskName "your-task-name"
```

### Assignments and outputs

```powershell
.\cc.ps1 assignments
.\cc.ps1 outputs
```

### External blockers

```powershell
.\cc.ps1 block -Reason "Need external credential"
.\cc.ps1 unblock -Reason "Credential has been provided"
```

### Self-tests

```powershell
.\cc.ps1 self-test
.\cc.ps1 plan-self-test
.\cc.ps1 wrapper-self-test
.\cc.ps1 orchestration-self-test
```

## Verification Profile Format

A profile defines the checks that the finish gate must respect.

```json
{
  "profile_id": "my-project",
  "name": "My Project Gate",
  "checks": [
    {
      "id": "frontend_build",
      "title": "Frontend Build",
      "required": true,
      "workdir": ".",
      "command": ["pnpm", "build"]
    },
    {
      "id": "rust_check",
      "title": "Rust Check",
      "required": true,
      "workdir": "src-tauri",
      "command": ["cargo", "check"]
    }
  ]
}
```

Field reference:

- `id`: stable check identifier
- `title`: human-readable name
- `required`: whether the check participates in the finish gate
- `workdir`: working directory relative to the target repository root
- `command`: command array executed by the controller

## Task Template Format

Task templates shape the run before verification starts.

Included templates:

- [`templates/default-tasks.json`](./templates/default-tasks.json)
- [`templates/self-test-tasks.json`](./templates/self-test-tasks.json)
- [`templates/desktop-plugin-host.example.json`](./templates/desktop-plugin-host.example.json)

Each task can define:

- `id`
- `title`
- `description`
- `required`
- `owner_hint`
- `depends_on`
- `parallel_group`

## RTK Usage

If you use RTK in your own environment, you can point Codex and planner execution at `rtk`:

```powershell
.\cc.ps1 run `
  -TaskName "my-task" `
  -Objective "my objective" `
  -Prompt "keep going until the gate passes" `
  -Profile ".\profiles\my-project.json" `
  -CodexCommand "rtk" `
  -PlannerCommand "rtk" `
  -Force
```

## Documentation

- [README.md](./README.md), English overview
- [README.zh-CN.md](./README.zh-CN.md), 中文说明和使用指南
- [CONTRIBUTING.md](./CONTRIBUTING.md), contribution and local testing notes
- [CHANGELOG.md](./CHANGELOG.md), release history

## Notes

- This repository ships the controller, not your project-specific verification scripts.
- You are expected to replace the starter profile with your own real checks.
- The default starter profile fails on purpose, so you do not accidentally think verification is wired up when it is not.

## License

[MIT](./LICENSE)
