param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$root = $state.paths.agent_outputs_root

$records = @()
if (Test-Path $root) {
  foreach ($file in @(Get-ChildItem -File $root -Filter *.json | Sort-Object LastWriteTime)) {
    $records += Read-JsonFile -Path $file.FullName
  }
}

[pscustomobject]@{
  run_id = $state.run_id
  total = @($records).Count
  outputs = @($records)
} | ForEach-Object {
  $result = $_
  if ($Detailed) {
    $result | ConvertTo-Json -Depth 100
  } else {
    [pscustomobject]@{
      RunId = $result.run_id
      TotalOutputs = $result.total
      Outputs = @($result.outputs | Select-Object agent_name, agent_role, task_id, summary, created_at)
    } | ConvertTo-Json -Depth 20
  }
}
