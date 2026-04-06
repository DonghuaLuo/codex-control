param(
  [Parameter(Mandatory = $true)]
  [string]$Objective,
  [string]$TaskName = '',
  [string]$Prompt = '',
  [string]$PromptFile = '',
  [string]$ProfilePath = '',
  [string]$TasksPath = '',
  [string]$RunId = '',
  [string]$ContinueFromRunId = '',
  [int]$MaxLoops = 4,
  [int]$CodexTimeoutSec = 600,
  [int]$PlannerTimeoutSec = 180,
  [string]$CodexCommand = 'codex',
  [string[]]$CodexPrefixArgs = @('codex'),
  [string[]]$CodexArgs = @('--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox', '--json'),
  [string]$PlannerCommand = 'codex',
  [string[]]$PlannerPrefixArgs = @('codex'),
  [string[]]$PlannerArgs = @('--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox'),
  [switch]$UsePlannerSubcommands = $true,
  [switch]$UseCodexSubcommands = $true,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-InitialPromptText {
  param(
    [string]$Prompt,
    [string]$PromptFile
  )

  if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    return Read-Utf8Text -Path (Resolve-Path $PromptFile)
  }

  if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    return $Prompt
  }

  throw 'Either Prompt or PromptFile is required.'
}

function Build-ControlPrompt {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State,
    [Parameter(Mandatory = $true)]
    [string]$UserPrompt
  )

  return @"
You are running inside a gated Codex CLI wrapper.

Hard requirements:
- Do not consider the task complete until the finish gate passes.
- Use the run state at: $($State.paths.run_state_path)
- The controller launches Codex without sandbox restrictions by default so real `pnpm build`, `cargo check`, and browser tooling can run in this repository.
- If you still see `spawn EPERM`, `spawnSync ... EPERM`, `browserType.launch: spawn EPERM`, or `os error 5` from Node/Vite/esbuild/Playwright/cargo, treat that as a real environment blocker. Do not rewrite the build chain or app logic just to satisfy a broken runtime. Record evidence and call block-run with a clear external blocker.
- Use these scripts to drive the run:
  - start is already done
  - update state: $((Join-Path $PSScriptRoot 'update-state.ps1'))
  - verify: $((Join-Path $PSScriptRoot 'verify.ps1'))
  - status: $((Join-Path $PSScriptRoot 'status.ps1'))
  - record agent output: $((Join-Path $PSScriptRoot 'record-agent-output.ps1'))
  - list agent outputs: $((Join-Path $PSScriptRoot 'list-agent-outputs.ps1'))
  - open rework: $((Join-Path $PSScriptRoot 'open-rework.ps1'))
  - block: $((Join-Path $PSScriptRoot 'block-run.ps1'))
  - unblock: $((Join-Path $PSScriptRoot 'unblock-run.ps1'))
  - finish gate: $((Join-Path $PSScriptRoot 'finish-gate.ps1'))
  - close run only after gate passes: $((Join-Path $PSScriptRoot 'close-run.ps1'))
- You must repeat implement -> verify -> fix -> reverify until the finish gate passes or there is a real external blocker.
- If blocked externally, call block-run and explain the blocker clearly.
- Record meaningful main-agent progress with record-agent-output using the exact parameters `-AgentName`, `-AgentRole`, `-Summary`, and `-Content`.
- Example main-agent progress call:
  `& '$recordAgentOutputScript' -RunStatePath '$($State.paths.run_state_path)' -AgentName 'main-agent' -AgentRole 'main-agent' -Summary 'Checked run state' -Content 'Read the current run state and confirmed the next execution step.'`
- Example worker progress call:
  `& '$recordAgentOutputScript' -RunStatePath '$($State.paths.run_state_path)' -AgentName 'worker-task-01' -AgentRole 'worker-agent' -TaskId 'task-01' -Summary 'Worker result recorded' -Content 'Task task-01 finished its latest implementation step.'`
- Do not invent unsupported parameter names when calling record-agent-output.

User objective:
$UserPrompt
"@
}

function Build-RejectPrompt {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State,
    [Parameter(Mandatory = $true)]
    [string]$GateJson,
    [Parameter(Mandatory = $true)]
    [string]$StatusJson
  )

  return @"
Finish gate rejected.
Do not stop.
Continue working in the same session until the gate passes.

Run state:
$($State.paths.run_state_path)

Gate output:
$GateJson

Status output:
$StatusJson
"@
}

function Get-ElapsedPrefix {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAt
  )

  $elapsedSec = [int]((Get-Date) - $StartedAt).TotalSeconds
  return "[{0}s]" -f $elapsedSec
}

function Format-CodexEventLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return $null
  }

  try {
    $event = $Line | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return "[codex][raw] $Line"
  }

  switch ($event.type) {
    'assistant_message' {
      if ($event.message) {
        return "[codex][assistant] $([string]$event.message)"
      }
      return '[codex][assistant]'
    }
    'thread.started' {
      return "[codex][thread] started: $($event.thread_id)"
    }
    'turn.started' {
      return '[codex] turn started'
    }
    'turn.completed' {
      $usage = $event.usage
      if ($usage) {
        return "[codex] turn completed (input=$($usage.input_tokens), cached=$($usage.cached_input_tokens), output=$($usage.output_tokens))"
      }
      return '[codex] turn completed'
    }
    'item.started' {
      $item = $event.item
      if ($null -eq $item) {
        return $null
      }

      $itemType = if ($item.type) { [string]$item.type } else { 'work item' }
      switch ($itemType) {
        'command_execution' { return $null }
        'agent_message' { return $null }
        default { return $null }
      }
    }
    'item.completed' {
      $item = $event.item
      if ($null -eq $item) {
        return $null
      }
      switch ($item.type) {
        'agent_message' {
          $text = [string]$item.text
          $text = $text -replace '\r?\n', ' '
          return "[codex][assistant] $text"
        }
        'command_execution' { return $null }
        default {
          return $null
        }
      }
    }
    default {
      return "[codex] $($event.type)"
    }
  }
}

$controllerRoot = Get-CodexControlRoot
$repoRoot = Get-RepoRoot
$planScript = Join-Path $PSScriptRoot 'plan-tasks.ps1'
$startScript = Join-Path $PSScriptRoot 'start-run.ps1'
$updateScript = Join-Path $PSScriptRoot 'update-state.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify.ps1'
$statusScript = Join-Path $PSScriptRoot 'status.ps1'
$gateScript = Join-Path $PSScriptRoot 'finish-gate.ps1'
$closeScript = Join-Path $PSScriptRoot 'close-run.ps1'
$recordAgentOutputScript = Join-Path $PSScriptRoot 'record-agent-output.ps1'
$blockScript = Join-Path $PSScriptRoot 'block-run.ps1'

if (-not $ProfilePath) {
  $ProfilePath = Get-DefaultProfilePath
}
$userPrompt = Get-InitialPromptText -Prompt $Prompt -PromptFile $PromptFile
if (-not $TasksPath) {
  Write-Host '[cc] no tasks template supplied. generating task plan from the current objective and prompt...'
  $generatedTasksRoot = Join-Path $controllerRoot 'generated-tasks'
  New-Item -ItemType Directory -Force -Path $generatedTasksRoot | Out-Null
  $autoTasksPath = Join-Path $generatedTasksRoot ("run-plan-{0}.json" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')))
  & $planScript `
    -Objective $Objective `
    -Prompt $userPrompt `
    -OutputPath $autoTasksPath `
    -TimeoutSec $PlannerTimeoutSec `
    -PlannerCommand $PlannerCommand `
    -PlannerPrefixArgs $PlannerPrefixArgs `
    -PlannerArgs $PlannerArgs `
    -UsePlannerSubcommands:$UsePlannerSubcommands | Out-Null
  $TasksPath = $autoTasksPath
  Write-Host "[cc] generated tasks: $TasksPath"
}
$startParams = @{
  Objective = $Objective
  PromptText = $userPrompt
  ProfilePath = $ProfilePath
  TasksPath = $TasksPath
  RunId = $RunId
  Force = $Force
}
if (-not [string]::IsNullOrWhiteSpace($TaskName)) {
  $startParams.TaskName = $TaskName
}
if (-not [string]::IsNullOrWhiteSpace($ContinueFromRunId)) {
  $startParams.ContinueFromRunId = $ContinueFromRunId
}
$startJson = & $startScript @startParams
$state = $startJson | ConvertFrom-Json
$runStatePath = $state.paths.run_state_path

& $updateScript -RunStatePath $runStatePath -Status IMPLEMENTING | Out-Null
$state = Load-RunState -RunStatePath $runStatePath

$codexArtifactsRoot = Join-Path $state.paths.artifacts_root 'codex'
New-Item -ItemType Directory -Force -Path $codexArtifactsRoot | Out-Null

$sessionStarted = $false
$lastMessage = ''

Write-Host "[cc] started run: $($state.run_id)"
if ($state.task_identity) {
  Write-Host "[cc] task: $($state.task_identity.task_name) [$($state.task_identity.task_slug)]"
}
Write-Host "[cc] objective: $Objective"
Write-Host "[cc] run state: $runStatePath"
Write-Host "[cc] max loops: $MaxLoops"

& $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary 'Run started' -Content ("objective={0}`nrun_state={1}" -f $Objective, $runStatePath) | Out-Null

for ($loop = 1; $loop -le $MaxLoops; $loop += 1) {
  $loopStartedAt = Get-Date
  $lastMessagePath = Join-Path $codexArtifactsRoot ("loop-{0:D2}.last.txt" -f $loop)
  $stdoutPath = Join-Path $codexArtifactsRoot ("loop-{0:D2}.stdout.jsonl" -f $loop)
  $stderrPath = Join-Path $codexArtifactsRoot ("loop-{0:D2}.stderr.log" -f $loop)

  if ($loop -eq 1) {
    $promptText = Build-ControlPrompt -State $state -UserPrompt $userPrompt
    if ($UseCodexSubcommands) {
      $command = @($CodexCommand) + @($CodexPrefixArgs) + @('exec') + @($CodexArgs) + @('-o', $lastMessagePath, '--cd', $repoRoot, '-')
    } else {
      $command = @($CodexCommand) + @($CodexArgs) + @('-OutputLastMessage', $lastMessagePath, '-WorkingDirectory', $repoRoot)
    }
    Write-Host "[cc] loop ${loop}/${MaxLoops}: starting initial codex run..."
    & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary ("Loop {0} started" -f $loop) -Content 'Starting initial Codex run.' | Out-Null
  } else {
    $gateJson = & $gateScript -RunStatePath $runStatePath 2>&1 | Out-String
    $statusJson = & $statusScript -RunStatePath $runStatePath -Detailed 2>&1 | Out-String
    $promptText = Build-RejectPrompt -State $state -GateJson $gateJson.Trim() -StatusJson $statusJson.Trim()
    if ($UseCodexSubcommands) {
      $resumeArgs = @($CodexArgs | Where-Object { $_ -ne '--sandbox' -and $_ -ne 'workspace-write' })
      $command = @($CodexCommand) + @($CodexPrefixArgs) + @('exec', 'resume', '--last') + @($resumeArgs) + @('-o', $lastMessagePath, '-')
    } else {
      $command = @($CodexCommand) + @($CodexArgs) + @('-OutputLastMessage', $lastMessagePath, '-WorkingDirectory', $repoRoot)
    }
    Write-Host "[cc] loop ${loop}/${MaxLoops}: finish gate rejected, resuming codex..."
    & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary ("Loop {0} resumed" -f $loop) -Content 'Finish gate rejected; resuming Codex with gate and status feedback.' | Out-Null
  }

  Write-Host "[cc] stdout log: $stdoutPath"
  Write-Host "[cc] stderr log: $stderrPath"

  $execution = Invoke-StreamingCommandWithInput `
    -Command $command `
    -WorkingDirectory $repoRoot `
    -StdoutPath $stdoutPath `
    -StderrPath $stderrPath `
    -InputText $promptText `
    -TimeoutSec $CodexTimeoutSec `
    -HeartbeatLabel '' `
    -OnStdoutLine {
      param($line)
      $display = Format-CodexEventLine -Line $line
      if (-not [string]::IsNullOrWhiteSpace($display)) {
        Write-Host ("{0} {1}" -f (Get-ElapsedPrefix -StartedAt $loopStartedAt), $display)
        if ($display -like '[codex][assistant]*') {
          & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary ("Loop {0} assistant output" -f $loop) -Content $display | Out-Null
        }
      }
    } `
    -OnStderrLine {
      param($line)
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-Host ("{0} [codex][stderr] {1}" -f (Get-ElapsedPrefix -StartedAt $loopStartedAt), $line)
      }
    }
  if ($execution.exit_code -ne 0) {
    Write-Host "[cc] codex loop $loop failed with exit code $($execution.exit_code)."
    & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary ("Loop {0} failed" -f $loop) -Content ("stdout={0}`nstderr={1}`nexit_code={2}" -f $stdoutPath, $stderrPath, $execution.exit_code) | Out-Null

    if ($loop -ge $MaxLoops) {
      & $blockScript -RunStatePath $runStatePath -Reason ("Codex command failed repeatedly; last exit code {0}" -f $execution.exit_code) -Evidence ("stdout={0}`nstderr={1}" -f $stdoutPath, $stderrPath) -NextRequiredAction 'Inspect command failure and resume the task after fixing the underlying issue.' | Out-Null
      break
    }

    $state = Load-RunState -RunStatePath $runStatePath
    continue
  }

  Write-Host "[cc] codex loop $loop finished."
  & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary ("Loop {0} finished" -f $loop) -Content ("stdout={0}`nstderr={1}" -f $stdoutPath, $stderrPath) | Out-Null

  if (Test-Path $lastMessagePath) {
    $lastMessage = Read-Utf8Text -Path $lastMessagePath
  }

  $global:LASTEXITCODE = 0
  & $gateScript -RunStatePath $runStatePath | Out-Null
  $gateExit = $LASTEXITCODE

  if ($gateExit -eq 0) {
    Write-Host '[cc] finish gate passed. closing run...'
    & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary 'Finish gate passed' -Content 'Closing run.' | Out-Null
    $closeJson = & $closeScript -RunStatePath $runStatePath
    $closePath = Join-Path $codexArtifactsRoot ("loop-{0:D2}.close-run.json" -f $loop)
    Write-Utf8Text -Path $closePath -Text $closeJson
    if (-not [string]::IsNullOrWhiteSpace($lastMessage)) {
      Write-Output $lastMessage
    }
    return
  }

  Write-Host '[cc] finish gate rejected. continuing...'
  & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary 'Finish gate rejected' -Content 'Continuing to next loop.' | Out-Null
  $state = Load-RunState -RunStatePath $runStatePath
  $sessionStarted = $true
}

$finalState = Load-RunState -RunStatePath $runStatePath
if ($finalState.status -eq 'BLOCKED_EXTERNAL') {
  Write-Host '[cc] run ended in BLOCKED_EXTERNAL.'
  & $recordAgentOutputScript -RunStatePath $runStatePath -AgentName 'main-agent' -AgentRole 'main-agent' -Summary 'Run blocked externally' -Content 'Stopping wrapper because the run has been marked as blocked.' | Out-Null
  $summary = & $statusScript -RunStatePath $runStatePath
  Write-Output $summary
  return
}

throw "Gated Codex reached MaxLoops=$MaxLoops before the finish gate passed. Check: $runStatePath"
