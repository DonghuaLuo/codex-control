param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$runScript = Join-Path $PSScriptRoot 'run-gated-codex.ps1'
$statusScript = Join-Path $PSScriptRoot 'status.ps1'
$controllerRoot = Get-CodexControlRoot

$output = & $runScript `
  -Objective 'gated codex wrapper self test' `
  -Prompt 'Say something short and stop.' `
  -ProfilePath (Join-Path $controllerRoot 'profiles\self-test-pass.json') `
  -CodexCommand 'powershell' `
  -CodexArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-codex.ps1')) `
  -PlannerCommand 'powershell' `
  -PlannerArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-task-planner.ps1')) `
  -UsePlannerSubcommands:$false `
  -UseCodexSubcommands:$false `
  -Force

$state = Load-RunState
$summary = & $statusScript -RunStatePath $state.paths.run_state_path | ConvertFrom-Json

if ($state.status -ne 'FINISHED') {
  throw "Expected gated codex self test to finish, got '$($state.status)'."
}

if (-not $summary.Run.CanFinish) {
  throw 'Expected status after close-run to remain gate-valid in FINISHED state.'
}

$report = [pscustomobject]@{
  ok = $true
  run_id = $state.run_id
  final_status = $state.status
  wrapper_output = $output
}

$report | ConvertTo-Json -Depth 100
