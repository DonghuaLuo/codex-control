# codex-control 中文说明

`codex-control` 是一个给 Codex CLI 用的外部强制闭环控制器。

它解决的是一个很实际的问题：很多 CLI agent 在“差一点完成”的状态就停了。代码改了，但没验。验挂了，但没人持续返工。过几小时再回来看，也不知道上一次到底做到哪了。

`codex-control` 的做法不是让 agent 更会“说完成了”，而是强制它进入一个有状态、有记录、有 gate 的执行循环。

## 它解决什么问题

典型的失败中间态有这些：

- 改了代码，但没有跑真实校验
- 校验失败了，但没有把失败记录成可追踪的问题单
- 任务被打断后，没有可恢复的 run 历史
- 多轮修改之后，不知道哪一轮做了什么、谁记录了什么、为什么被 gate 卡住

`codex-control` 把这件事变成：

`计划 -> 实施 -> 校验 -> 修复 -> 重校验 -> 通过 finish gate -> 结束`

不通过 gate，就不算完成。

## 核心能力

- 把一次任务落成一个持久化 run
- 保存任务清单、assignment、failure、agent output 和校验产物
- 可以先自动拆任务，再驱动 Codex CLI 执行
- required check 失败时会自动开 failure
- 支持外部阻塞记录和解除阻塞
- 支持按任务名续跑
- 自带多组 self-test，验证 planner、wrapper、gate 和 orchestration 流程

## 目录结构

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

这些运行期文件不会进入版本库：

- `runs/`
- `generated-tasks/`
- `active-run.json`
- `task-registry.json`

## 运行前提

- Windows PowerShell 5.1 或 PowerShell 7
- 本机已安装并可直接调用 `codex`
- 可选：如果你自己在用 RTK，也可以把 `CodexCommand` 和 `PlannerCommand` 指向 `rtk`

## 仓库根目录如何判断

`codex-control` 支持两种放法：

1. 它自己就是一个独立仓库
2. 它只是你业务仓库里的一个子目录

默认规则：

- 如果 `codex-control` 目录自己包含 `.git`，就把当前目录当成目标仓库根目录
- 否则，把它的父目录当成目标仓库根目录

也可以手动指定：

```powershell
$env:CODEX_CONTROL_REPO_ROOT = "D:\path\to\your-repo"
```

## 快速开始

### 1. 准备 profile

仓库自带的 [`profiles/default.json`](./profiles/default.json) 会故意失败。

这是刻意设计的。因为如果默认就“看起来能跑”，很容易让人误以为已经接好了真实校验链，实际上只是空壳。

你可以从这些文件开始：

- [`profiles/default.json`](./profiles/default.json)
- [`profiles/default-gated.json`](./profiles/default-gated.json)
- [`profiles/node-rust-monorepo.example.json`](./profiles/node-rust-monorepo.example.json)

比如：

```powershell
Copy-Item .\profiles\node-rust-monorepo.example.json .\profiles\my-project.json
```

然后把里面的：

- `workdir`
- `command`

改成你自己项目里的真实校验命令，例如 `pnpm build`、`cargo check`、`pytest`、`go test`。

### 2. 启动一个新任务

```powershell
.\cc.ps1 run `
  -TaskName "fix-plugin-host" `
  -Objective "Repair plugin host parity and close the verification gap" `
  -Prompt "Continue until the verification profile passes." `
  -Profile ".\profiles\my-project.json" `
  -Force
```

### 3. 查看当前进度

```powershell
.\cc.ps1 status
.\cc.ps1 tasks
.\cc.ps1 assignments
.\cc.ps1 outputs
```

### 4. 以后按任务名续跑

```powershell
.\cc.ps1 resume `
  -TaskName "fix-plugin-host" `
  -Objective "Continue the previous workstream" `
  -Prompt "Resume from the last run and keep going until the gate passes." `
  -Profile ".\profiles\my-project.json" `
  -Force
```

## 常用命令

### 运行闭环任务

```powershell
.\cc.ps1 run `
  -TaskName "your-task-name" `
  -Objective "your objective" `
  -Prompt "your implementation instructions" `
  -Profile ".\profiles\my-project.json" `
  -Force
```

### 只做拆任务

```powershell
.\cc.ps1 plan `
  -Objective "your objective" `
  -Prompt "Analyze this request and split it into execution-ready tasks."
```

### 查看状态

```powershell
.\cc.ps1 status
.\cc.ps1 status -Detailed
```

### 查看任务历史

```powershell
.\cc.ps1 task-history -TaskName "your-task-name"
```

### 标记外部阻塞

```powershell
.\cc.ps1 block -Reason "Need external credential"
.\cc.ps1 unblock -Reason "Credential has been provided"
```

### 跑内置自测

```powershell
.\cc.ps1 self-test
.\cc.ps1 plan-self-test
.\cc.ps1 wrapper-self-test
.\cc.ps1 orchestration-self-test
```

## Profile 格式

profile 决定 finish gate 要看哪些检查项。

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

- `id`：稳定的检查项标识
- `title`：展示名称
- `required`：是否参与 finish gate
- `workdir`：相对目标仓库根目录的工作目录
- `command`：要执行的命令数组

## Task Template

任务模板决定 run 一开始有哪些 task。

当前内置了这些模板：

- [`templates/default-tasks.json`](./templates/default-tasks.json)
- [`templates/self-test-tasks.json`](./templates/self-test-tasks.json)
- [`templates/desktop-plugin-host.example.json`](./templates/desktop-plugin-host.example.json)

可用字段包括：

- `id`
- `title`
- `description`
- `required`
- `owner_hint`
- `depends_on`
- `parallel_group`

## finish gate 的通过条件

必须同时满足：

- 所有 required tasks 已完成
- 所有 required tasks 已标记 verified
- 所有 required checks 已通过
- 没有 open failures
- 没有 open external blockers
- run 状态处于 `READY_TO_FINISH` 或 `FINISHED`

## RTK 用法

如果你在自己的环境里使用 RTK，可以这样跑：

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

## 最后提醒

- 这个仓库只提供控制器本体，不包含你的业务校验脚本
- 真正决定任务“是否算完成”的，是你自己配置进去的 profile
- 默认 starter profile 会失败，这是为了防止你误以为已经接好了真实验证链

英文首页见 [README.md](./README.md)。
