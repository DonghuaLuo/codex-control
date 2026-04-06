param(
  [Parameter(Mandatory = $true)]
  [string]$Objective,
  [string]$Prompt = '',
  [string]$PromptFile = '',
  [string]$OutputPath = '',
  [int]$TimeoutSec = 180,
  [string]$PlannerCommand = 'codex',
  [string[]]$PlannerPrefixArgs = @('codex'),
  [string[]]$PlannerArgs = @('--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox'),
  [switch]$UsePlannerSubcommands = $true
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function New-TaskId {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Index
  )

  return ('task-{0:D2}' -f $Index)
}

function Build-FallbackPlan {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Objective,
    [Parameter(Mandatory = $true)]
    [string]$UserPrompt,
    [Parameter(Mandatory = $true)]
    [string]$Reason
  )

  $rawItems = @()
  $asciiColonIndex = $UserPrompt.LastIndexOf(':')
  $fullWidthColonIndex = $UserPrompt.LastIndexOf([char]0xFF1A)
  $splitIndex = [Math]::Max($asciiColonIndex, $fullWidthColonIndex)

  if ($splitIndex -ge 0 -and $splitIndex + 1 -lt $UserPrompt.Length) {
    $tail = $UserPrompt.Substring($splitIndex + 1).Trim()
    $stopIndex = $tail.IndexOf([char]0x3002)
    if ($stopIndex -lt 0) {
      $stopIndex = $tail.IndexOf('.')
    }
    if ($stopIndex -gt 0) {
      $tail = $tail.Substring(0, $stopIndex)
    }
    $rawItems = @($tail -split '[,\uFF0C\u3001]') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  }

  $tasks = @()
  $index = 1

  if (@($rawItems).Count -gt 0) {
    foreach ($item in $rawItems) {
      $tasks += [pscustomobject]@{
        id = New-TaskId -Index $index
        title = $item
        description = "Continue work on: $item"
        required = $true
        source = 'fallback'
      }
      $index += 1
    }
  } else {
    $tasks += [pscustomobject]@{
      id = New-TaskId -Index $index
      title = 'Analyze Request'
      description = "Analyze the current objective and lock the implementation boundary: $Objective"
      required = $true
      source = 'fallback'
    }
    $index += 1
    $tasks += [pscustomobject]@{
      id = New-TaskId -Index $index
      title = 'Implement Core Work'
      description = 'Complete the main code or script work required by the current objective.'
      required = $true
      source = 'fallback'
    }
    $index += 1
  }

  $tasks += [pscustomobject]@{
    id = New-TaskId -Index $index
    title = 'Verify And Fix'
    description = 'Run verification, then fix and retest until checks pass or an external blocker is recorded.'
    required = $true
    source = 'fallback'
  }

  return [pscustomobject]@{
    planner = 'fallback'
    fallback_reason = $Reason
    tasks = @($tasks)
  }
}

function Get-PlanningPrompt {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Objective,
    [Parameter(Mandatory = $true)]
    [string]$UserPrompt
  )

  return @"
You are planning work for a gated Codex execution.

Task:
- Analyze the objective and prompt.
- Break the work into 2-8 concrete tasks suitable for execution and verification.
- Prefer tasks that are implementation-meaningful and delegation-friendly.
- Use stable ids in kebab-case.
- Do not assume this is a specific project unless the prompt clearly implies one.
- The task list must be project-agnostic by default and derived from the request itself.

Objective:
$Objective

Prompt:
$UserPrompt
"@
}

if (-not $OutputPath) {
  $generatedRoot = Join-Path (Get-CodexControlRoot) 'generated-tasks'
  New-Item -ItemType Directory -Force -Path $generatedRoot | Out-Null
  $OutputPath = Join-Path $generatedRoot ("autoplan-{0}.json" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')))
}

if ([string]::IsNullOrWhiteSpace($PromptFile) -and [string]::IsNullOrWhiteSpace($Prompt)) {
  throw 'plan-tasks requires Prompt or PromptFile.'
}

$promptText = if ($PromptFile) {
  Read-Utf8Text -Path (Resolve-Path $PromptFile)
} else {
  $Prompt
}

$planningPrompt = Get-PlanningPrompt -Objective $Objective -UserPrompt $promptText
$schemaPath = Join-Path (Get-CodexControlRoot) 'schemas\task-plan.schema.json'
$repoRoot = Get-RepoRoot
$plannerStdout = [System.IO.Path]::ChangeExtension($OutputPath, '.stdout.log')
$plannerStderr = [System.IO.Path]::ChangeExtension($OutputPath, '.stderr.log')

if ($UsePlannerSubcommands) {
  $command = @($PlannerCommand) + @($PlannerPrefixArgs) + @('exec') + @($PlannerArgs) + @('--output-schema', $schemaPath, '-o', $OutputPath, '--cd', $repoRoot, '-')
} else {
  $command = @($PlannerCommand) + @($PlannerArgs) + @('-OutputLastMessage', $OutputPath, '-WorkingDirectory', $repoRoot)
}

$execution = Invoke-LoggedCommandWithInput -Command $command -WorkingDirectory $repoRoot -StdoutPath $plannerStdout -StderrPath $plannerStderr -InputText $planningPrompt -TimeoutSec $TimeoutSec
$plan = $null
if ($execution.exit_code -eq 0 -and (Test-Path $OutputPath)) {
  try {
    $plan = Read-JsonFile -Path $OutputPath
    if (-not $plan.tasks -or @($plan.tasks).Count -lt 1) {
      $plan = $null
    }
  } catch {
    $plan = $null
  }
}

if ($null -eq $plan) {
  $fallbackReason = if ($execution.timed_out) {
    "planner timed out after $TimeoutSec seconds"
  } else {
    "planner failed; see $plannerStderr"
  }
  $plan = Build-FallbackPlan -Objective $Objective -UserPrompt $promptText -Reason $fallbackReason
  Write-JsonFile -Path $OutputPath -Data $plan
}

$plan | ConvertTo-Json -Depth 100
