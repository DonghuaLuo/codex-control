param(
  [string]$RunId = '',
  [string]$RunStatePath = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$state = Recompute-RunState -State $state
Save-RunState -State $state
Set-ActiveRunPointer -State $state

$reasons = @()
if (-not $state.final_gate.all_required_tasks_done) {
  $reasons += 'required tasks are not all done'
}
if (-not $state.final_gate.all_required_tasks_verified) {
  $reasons += 'required tasks are not all verified'
}
if (-not $state.final_gate.all_required_checks_passed) {
  $reasons += 'required checks have not all passed'
}
if (-not $state.final_gate.no_open_failures) {
  $reasons += 'open failures still exist'
}
if (-not $state.final_gate.no_external_blockers) {
  $reasons += 'external blockers still exist'
}
if (-not $state.final_gate.status_ready) {
  $reasons += "run status is '$($state.status)' instead of READY_TO_FINISH or FINISHED"
}

$report = [pscustomobject]@{
  run_id = $state.run_id
  status = $state.status
  can_finish = $state.can_finish
  final_gate = $state.final_gate
  reasons = @($reasons)
}

$artifactPath = Join-Path $state.paths.artifacts_root 'finish-gate.result.json'
Write-JsonFile -Path $artifactPath -Data $report

$report | ConvertTo-Json -Depth 100

if (-not $state.can_finish) {
  exit 1
}
