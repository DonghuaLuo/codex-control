param(
  [Parameter(Position = 0)]
  [ValidateSet('run', 'start', 'plan', 'status', 'verify', 'gate', 'close', 'block', 'unblock', 'tasks', 'task-history', 'assignments', 'outputs', 'resume', 'self-test', 'wrapper-self-test', 'plan-self-test', 'orchestration-self-test')]
  [string]$Action = 'status',

  [string]$Objective = '',
  [string]$TaskName = '',
  [string]$Prompt = '',
  [string]$PromptFile = '',
  [string]$Profile = '',
  [string]$Tasks = '',
  [int]$MaxLoops = 4,
  [int]$CodexTimeoutSec = 600,
  [string]$CodexCommand = '',
  [string]$PlannerCommand = '',
  [string]$Reason = '',
  [string]$Evidence = '',
  [string]$NextAction = '',
  [string]$NextStatus = 'IMPLEMENTING',
  [switch]$Detailed,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$controlRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsRoot = Join-Path $controlRoot 'scripts'

function Resolve-OptionalPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return (Join-Path $controlRoot $Path)
}

$profilePath = Resolve-OptionalPath -Path $Profile
$tasksPath = Resolve-OptionalPath -Path $Tasks
$codexCommandValue = if ([string]::IsNullOrWhiteSpace($CodexCommand)) { 'codex' } else { $CodexCommand }
$plannerCommandValue = if ([string]::IsNullOrWhiteSpace($PlannerCommand)) { $codexCommandValue } else { $PlannerCommand }

switch ($Action) {
  'run' {
    if ([string]::IsNullOrWhiteSpace($Objective)) {
      throw 'Action run requires -Objective.'
    }
    if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
      throw 'Action run requires -Prompt or -PromptFile.'
    }

    & (Join-Path $scriptsRoot 'run-gated-codex.ps1') `
      -Objective $Objective `
      -TaskName $TaskName `
      -Prompt $Prompt `
      -PromptFile $PromptFile `
      -ProfilePath $profilePath `
      -TasksPath $tasksPath `
      -MaxLoops $MaxLoops `
      -CodexTimeoutSec $CodexTimeoutSec `
      -CodexCommand $codexCommandValue `
      -PlannerCommand $plannerCommandValue `
      -Force:$Force
    break
  }

  'start' {
    if ([string]::IsNullOrWhiteSpace($Objective)) {
      throw 'Action start requires -Objective.'
    }

    & (Join-Path $scriptsRoot 'start-run.ps1') `
      -Objective $Objective `
      -TaskName $TaskName `
      -ProfilePath $profilePath `
      -TasksPath $tasksPath `
      -Force:$Force
    break
  }

  'plan' {
    if ([string]::IsNullOrWhiteSpace($Objective)) {
      throw 'Action plan requires -Objective.'
    }
    if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
      throw 'Action plan requires -Prompt or -PromptFile.'
    }

    & (Join-Path $scriptsRoot 'plan-tasks.ps1') `
      -Objective $Objective `
      -Prompt $Prompt `
      -PromptFile $PromptFile `
      -PlannerCommand $plannerCommandValue
    break
  }

  'status' {
    & (Join-Path $scriptsRoot 'status.ps1') -Detailed:$Detailed
    break
  }

  'tasks' {
    & (Join-Path $scriptsRoot 'list-tasks.ps1')
    break
  }

  'task-history' {
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
      throw 'Action task-history requires -TaskName.'
    }

    & (Join-Path $scriptsRoot 'task-history.ps1') `
      -TaskName $TaskName `
      -Detailed:$Detailed
    break
  }

  'assignments' {
    & (Join-Path $scriptsRoot 'list-assignments.ps1') -Detailed:$Detailed
    break
  }

  'outputs' {
    & (Join-Path $scriptsRoot 'list-agent-outputs.ps1') -Detailed:$Detailed
    break
  }

  'verify' {
    & (Join-Path $scriptsRoot 'verify.ps1')
    break
  }

  'gate' {
    & (Join-Path $scriptsRoot 'finish-gate.ps1')
    break
  }

  'close' {
    & (Join-Path $scriptsRoot 'close-run.ps1')
    break
  }

  'block' {
    if ([string]::IsNullOrWhiteSpace($Reason)) {
      throw 'Action block requires -Reason.'
    }

    & (Join-Path $scriptsRoot 'block-run.ps1') `
      -Reason $Reason `
      -Evidence $Evidence `
      -NextRequiredAction $NextAction
    break
  }

  'unblock' {
    if ([string]::IsNullOrWhiteSpace($Reason)) {
      throw 'Action unblock requires -Reason.'
    }

    & (Join-Path $scriptsRoot 'unblock-run.ps1') `
      -Reason $Reason `
      -NextStatus $NextStatus
    break
  }

  'resume' {
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
      throw 'Action resume requires -TaskName.'
    }
    if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
      throw 'Action resume requires -Prompt or -PromptFile.'
    }

    & (Join-Path $scriptsRoot 'resume-task.ps1') `
      -TaskName $TaskName `
      -Objective $Objective `
      -Prompt $Prompt `
      -PromptFile $PromptFile `
      -ProfilePath $profilePath `
      -TasksPath $tasksPath `
      -MaxLoops $MaxLoops `
      -CodexTimeoutSec $CodexTimeoutSec `
      -CodexCommand $codexCommandValue `
      -PlannerCommand $plannerCommandValue `
      -Force:$Force
    break
  }

  'self-test' {
    & (Join-Path $scriptsRoot 'self-test.ps1')
    break
  }

  'wrapper-self-test' {
    & (Join-Path $scriptsRoot 'run-gated-codex-self-test.ps1')
    break
  }

  'plan-self-test' {
    & (Join-Path $scriptsRoot 'plan-tasks-self-test.ps1')
    break
  }

  'orchestration-self-test' {
    & (Join-Path $scriptsRoot 'orchestration-self-test.ps1')
    break
  }
}
