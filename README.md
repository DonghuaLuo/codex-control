# codex-control

A gated control loop for Codex CLI that keeps planning, implementing, verifying, reopening failures, and retrying until the finish gate passes.

`codex-control` 是一个给 Codex CLI 用的外部强制闭环控制器。它把“开工一次就停”的单次调用，变成一个可追踪、可返工、可验收的任务执行循环。

## What It Does

- 把一次用户请求落成一个 run，并持久化状态、任务、assignment、failure、agent output。
- 可以先自动拆任务，再驱动 Codex CLI 执行实现。
- 在每一轮后自动执行验证命令。
- 验证失败时自动开 failure，要求继续修复并重新验证。
- 只有当 finish gate 满足时才允许结束 run。
- 支持外部阻塞记录、解除阻塞、按任务名续跑、查看历史和输出。

## Why This Exists

普通的 CLI agent 很容易停在这些中间态：

- 代码改了一半
- 任务做了但没验证
- 验证失败了但没有持续返工
- 没有结构化 run 历史，后续很难 resume

`codex-control` 的目标是把这些中间态显式化，并强制进入：

`plan -> implement -> verify -> fix -> reverify -> finish-gate`

## Repository Layout

```text
.
├─ cc.ps1                     # Main entrypoint
├─ cc.cmd                     # Windows wrapper
├─ profiles/                  # Verification profiles
├─ schemas/                   # JSON schemas used by planning
├─ scripts/                   # Controller implementation
└─ templates/                 # Task templates
```

运行时产物不会进入版本库：

- `runs/`
- `generated-tasks/`
- `active-run.json`
- `task-registry.json`

## Prerequisites

- Windows PowerShell 5.1+ 或 PowerShell 7
- 已安装并可直接调用的 `codex` CLI
- 可选：如果你自己在用 RTK，也可以把命令包装为 `rtk codex`

## Repo Root Resolution

`codex-control` 既可以独立放成一个仓库，也可以作为子目录嵌入你的业务仓库。

默认规则：

- 如果 `codex-control` 目录本身包含 `.git`，它会把当前目录当成目标仓库根目录。
- 否则，它会把父目录当成目标仓库根目录。

你也可以显式指定：

```powershell
$env:CODEX_CONTROL_REPO_ROOT = "D:\path\to\your-repo"
```

## Quick Start

### 1. Clone or copy into your repo

独立克隆或作为子目录放进你的项目都可以。

### 2. Customize the default profile

仓库自带的 [`profiles/default.json`](./profiles/default.json) 会故意失败，提醒你先配置真实验证命令。

如果你的项目是前端 + Rust 单仓，可以从这个示例开始：

- [`profiles/node-rust-monorepo.example.json`](./profiles/node-rust-monorepo.example.json)

最常见的做法是复制一份：

```powershell
Copy-Item .\profiles\node-rust-monorepo.example.json .\profiles\my-project.json
```

然后把里面的 `command` / `workdir` 改成你的真实校验链。

### 3. Run a task

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

### 5. Resume by task name

```powershell
.\cc.ps1 resume `
  -TaskName "fix-plugin-host" `
  -Objective "Continue the previous workstream" `
  -Prompt "Resume from the last run and keep going until the gate passes." `
  -Profile ".\profiles\my-project.json" `
  -Force
```

## Main Commands

### Start a new gated run

```powershell
.\cc.ps1 run `
  -TaskName "your-task-name" `
  -Objective "your objective" `
  -Prompt "your implementation instructions" `
  -Profile ".\profiles\my-project.json" `
  -Force
```

### Generate a plan only

```powershell
.\cc.ps1 plan `
  -Objective "your objective" `
  -Prompt "analyze this request and split it into tasks"
```

### Show run status

```powershell
.\cc.ps1 status
.\cc.ps1 status -Detailed
```

### Show task history

```powershell
.\cc.ps1 task-history -TaskName "your-task-name"
```

### Block / unblock external dependencies

```powershell
.\cc.ps1 block -Reason "Need external credential"
.\cc.ps1 unblock -Reason "Credential has been provided"
```

### Run self-tests

```powershell
.\cc.ps1 self-test
.\cc.ps1 plan-self-test
.\cc.ps1 wrapper-self-test
.\cc.ps1 orchestration-self-test
```

## Profile Format

A profile is a JSON file that defines the required verification checks for the finish gate.

Example:

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

字段说明：

- `id`: 稳定 check 标识
- `title`: 展示名称
- `required`: 是否参与 finish gate
- `workdir`: 相对目标仓库根目录的工作目录
- `command`: 要执行的命令数组

## How The Gate Works

finish gate 通过，必须同时满足：

- 所有 required tasks 都完成
- 所有 required tasks 都标记为 verified
- 所有 required checks 都通过
- 没有 open failures
- 没有 open external blockers
- run status 处于 `READY_TO_FINISH` 或 `FINISHED`

## Optional RTK Usage

如果你在自己的环境里使用 RTK，可以这样调用：

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

## Notes

- 这个仓库只提供控制器本体，不包含你的业务校验脚本。
- 你应该根据自己的项目，把 profile 里的验证命令替换成真实的 `pnpm build`、`cargo check`、`pytest`、`go test` 等。
- 默认 starter profile 会失败，这是有意设计，用来避免“没接入真实校验也误以为已经接好”。

## License

[MIT](./LICENSE)
