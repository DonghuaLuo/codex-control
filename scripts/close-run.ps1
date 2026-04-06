param(
  [string]$RunId = '',
  [string]$RunStatePath = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath

& (Join-Path $PSScriptRoot 'finish-gate.ps1') -RunStatePath $state.paths.run_state_path | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'Finish gate rejected the run. close-run aborted.'
}

Assert-ValidTransition -From $state.status -To 'FINISHED'
$state.closeout = [pscustomobject]@{
  gate_passed_at = Get-IsoNow
  closed_from_status = $state.status
}
$state.status = 'FINISHED'
$state.timestamps.completed_at = Get-IsoNow
$state = Recompute-RunState -State $state
Save-RunState -State $state
Sync-TaskFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$state | ConvertTo-Json -Depth 100
