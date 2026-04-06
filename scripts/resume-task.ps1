param(
  [Parameter(Mandatory = $true)]
  [string]$TaskName,
  [string]$Objective = '',
  [string]$Prompt = '',
  [string]$PromptFile = '',
  [string]$ProfilePath = '',
  [string]$TasksPath = '',
  [int]$MaxLoops = 4,
  [int]$CodexTimeoutSec = 600,
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

$registry = Read-TaskRegistry
$taskSlug = Convert-ToTaskSlug -TaskName $TaskName
$entry = @($registry.tasks | Where-Object { $_.task_slug -eq $taskSlug -or $_.task_name -eq $TaskName }) | Select-Object -First 1
if ($null -eq $entry) {
  throw "Task '$TaskName' not found in task registry."
}

if ([string]::IsNullOrWhiteSpace($Prompt) -and [string]::IsNullOrWhiteSpace($PromptFile)) {
  throw 'resume-task requires -Prompt or -PromptFile to describe the new task requirements.'
}

$runScript = Join-Path $PSScriptRoot 'run-gated-codex.ps1'
$nextObjective = if ([string]::IsNullOrWhiteSpace($Objective)) { $entry.latest_objective } else { $Objective }

& $runScript `
  -Objective $nextObjective `
  -TaskName $entry.task_name `
  -Prompt $Prompt `
  -PromptFile $PromptFile `
  -ProfilePath $ProfilePath `
  -TasksPath $TasksPath `
  -ContinueFromRunId $entry.latest_run_id `
  -MaxLoops $MaxLoops `
  -CodexTimeoutSec $CodexTimeoutSec `
  -CodexCommand $CodexCommand `
  -CodexPrefixArgs $CodexPrefixArgs `
  -CodexArgs $CodexArgs `
  -PlannerCommand $PlannerCommand `
  -PlannerPrefixArgs $PlannerPrefixArgs `
  -PlannerArgs $PlannerArgs `
  -UsePlannerSubcommands:$UsePlannerSubcommands `
  -UseCodexSubcommands:$UseCodexSubcommands `
  -Force:$Force
