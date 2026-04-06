param(
  [Parameter(Mandatory = $true)]
  [string]$TaskName,
  [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$registry = Read-TaskRegistry
$taskSlug = Convert-ToTaskSlug -TaskName $TaskName
$entry = @($registry.tasks | Where-Object { $_.task_slug -eq $taskSlug -or $_.task_name -eq $TaskName }) | Select-Object -First 1
if ($null -eq $entry) {
  throw "Task '$TaskName' not found in task registry."
}

[pscustomobject]@{
  task_name = $entry.task_name
  task_slug = $entry.task_slug
  latest_status = $entry.latest_status
  latest_run_id = $entry.latest_run_id
  active_run_id = $entry.active_run_id
  latest_objective = $entry.latest_objective
  latest_prompt = $(if ($entry.PSObject.Properties.Name -contains 'latest_prompt') { $entry.latest_prompt } else { $null })
  open_failures = $entry.open_failures
  open_blockers = $entry.open_blockers
  run_history = @($entry.run_history)
  runs = @($entry.runs)
} | ForEach-Object {
  $result = $_
  if ($Detailed) {
    $result | ConvertTo-Json -Depth 100
  } else {
    [pscustomobject]@{
      Task = [pscustomobject]@{
        TaskName = $result.task_name
        TaskSlug = $result.task_slug
        LatestStatus = $result.latest_status
        LatestRunId = $result.latest_run_id
        ActiveRunId = $result.active_run_id
        Objective = $result.latest_objective
        Prompt = $result.latest_prompt
        OpenFailures = $result.open_failures
        OpenBlockers = $result.open_blockers
        RunCount = @($result.run_history).Count
      }
      Runs = @($result.runs | Select-Object run_id, status, objective, created_at, updated_at, completed_at)
    } | ConvertTo-Json -Depth 20
  }
}
