param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$script = Join-Path $PSScriptRoot 'plan-tasks.ps1'
$outputPath = Join-Path (Get-CodexControlRoot) 'generated-tasks\self-test-plan.json'

$planJson = & $script `
  -Objective 'self test planning' `
  -Prompt 'Analyze this request and split it into tasks.' `
  -OutputPath $outputPath `
  -PlannerCommand 'powershell' `
  -PlannerArgs @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-task-planner.ps1')) `
  -UsePlannerSubcommands:$false

$plan = $planJson | ConvertFrom-Json
if (@($plan.tasks).Count -lt 2) {
  throw 'Expected mock planner to produce at least two tasks.'
}

$report = [pscustomobject]@{
  ok = $true
  output_path = $outputPath
  task_count = @($plan.tasks).Count
}

$report | ConvertTo-Json -Depth 100
