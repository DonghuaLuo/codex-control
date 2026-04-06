param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$runScript = Join-Path $PSScriptRoot 'run-gated-codex.ps1'
$recordScript = Join-Path $PSScriptRoot 'record-agent-output.ps1'
$historyScript = Join-Path $PSScriptRoot 'task-history.ps1'
$assignmentsScript = Join-Path $PSScriptRoot 'list-assignments.ps1'
$outputsScript = Join-Path $PSScriptRoot 'list-agent-outputs.ps1'
$resumeScript = Join-Path $PSScriptRoot 'resume-task.ps1'
$controllerRoot = Get-CodexControlRoot
$taskName = 'orchestration self test'

$null = & $runScript `
  -Objective 'orchestration self test' `
  -TaskName $taskName `
  -Prompt 'Create a small run and stop only when the gate passes.' `
  -ProfilePath (Join-Path $controllerRoot 'profiles\self-test-pass.json') `
  -PlannerCommand 'powershell' `
  -PlannerArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-task-planner.ps1')) `
  -UsePlannerSubcommands:$false `
  -CodexCommand 'powershell' `
  -CodexArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-codex.ps1')) `
  -UseCodexSubcommands:$false `
  -Force

$state = Load-RunState
$runStatePath = $state.paths.run_state_path
$firstTaskId = @($state.tasks | Select-Object -First 1).id
& $recordScript -RunStatePath $runStatePath -AgentName 'main-orchestrator' -AgentRole 'main-agent' -TaskId $firstTaskId -Summary 'Recorded orchestration output' -Content 'Main agent recorded a synthetic orchestration output.' | Out-Null
& $recordScript -RunStatePath $runStatePath -AgentRole 'main-agent' -Message 'Alias-only main agent progress message.' | Out-Null
& $recordScript -RunStatePath $runStatePath -AgentRole 'worker-agent' -TaskId $firstTaskId -Title 'Alias worker summary' -Body 'Alias worker body.' | Out-Null

$history = & $historyScript -TaskName $taskName -Detailed | ConvertFrom-Json
if ($history.latest_run_id -ne $state.run_id) {
  throw 'task-history did not point to the latest run.'
}

$assignments = & $assignmentsScript -RunStatePath $runStatePath | ConvertFrom-Json
if (@($assignments.assignments).Count -lt 1) {
  throw 'Expected at least one assignment in orchestration self test.'
}

$outputs = & $outputsScript -RunStatePath $runStatePath | ConvertFrom-Json
if (@($outputs.outputs).Count -lt 3) {
  throw 'Expected alias-compatible record-agent-output calls to produce at least three outputs in orchestration self test.'
}

$null = & $resumeScript `
  -TaskName $taskName `
  -Objective 'orchestration self test resumed' `
  -Prompt 'Resume this task and finish another gated run.' `
  -ProfilePath (Join-Path $controllerRoot 'profiles\self-test-pass.json') `
  -PlannerCommand 'powershell' `
  -PlannerArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-task-planner.ps1')) `
  -UsePlannerSubcommands:$false `
  -CodexCommand 'powershell' `
  -CodexArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-codex.ps1')) `
  -UseCodexSubcommands:$false `
  -Force

$historyAfterResume = & $historyScript -TaskName $taskName -Detailed | ConvertFrom-Json
if (@($historyAfterResume.run_history).Count -lt 2) {
  throw 'Expected resume flow to append another run to task history.'
}

$report = [pscustomobject]@{
  ok = $true
  task_name = $taskName
  latest_run_id = $historyAfterResume.latest_run_id
  run_history_count = @($historyAfterResume.run_history).Count
  assignment_count = @($assignments.assignments).Count
  output_count = @($outputs.outputs).Count
}

$report | ConvertTo-Json -Depth 100
