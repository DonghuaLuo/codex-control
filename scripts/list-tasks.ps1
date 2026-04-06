param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$registry = Read-TaskRegistry
$tasks = @($registry.tasks | Sort-Object updated_at -Descending)

[pscustomobject]@{
  total = @($tasks).Count
  tasks = @($tasks | ForEach-Object {
      [pscustomobject]@{
        TaskName = $_.task_name
        Objective = $_.latest_objective
        Prompt = $(if ($_.PSObject.Properties.Name -contains 'latest_prompt') { $_.latest_prompt } else { $null })
      }
    })
} | ConvertTo-Json -Depth 100
