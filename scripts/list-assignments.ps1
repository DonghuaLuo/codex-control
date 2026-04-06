param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$root = $state.paths.assignments_root

$records = @()
if (Test-Path $root) {
  foreach ($file in @(Get-ChildItem -File $root -Filter *.json | Sort-Object LastWriteTime)) {
    $records += Read-JsonFile -Path $file.FullName
  }
} else {
  $records = @($state.assignments)
}

[pscustomobject]@{
  run_id = $state.run_id
  task_identity = $state.task_identity
  total = @($records).Count
  assignments = @($records)
} | ForEach-Object {
  $result = $_
  if ($Detailed) {
    $result | ConvertTo-Json -Depth 100
  } else {
    [pscustomobject]@{
      Run = [pscustomobject]@{
        TaskName = $result.task_identity.task_name
        RunId = $result.run_id
        TotalAssignments = $result.total
      }
      Assignments = @($result.assignments | Select-Object id, agent_name, agent_role, task_ids, depends_on, parallel_group, status)
    } | ConvertTo-Json -Depth 20
  }
}
