param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [string]$TaskId = '',
  [Parameter(Mandatory = $true)]
  [ValidateSet('product_defect', 'framework_failure', 'result_drift', 'verification_failure')]
  [string]$FailureType,
  [Parameter(Mandatory = $true)]
  [string]$Summary,
  [string]$SourceCheckId = '',
  [string]$Details = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$task = $null
if ($TaskId) {
  $task = @($state.tasks | Where-Object { $_.id -eq $TaskId }) | Select-Object -First 1
}
if ($TaskId -and -not $task) {
  throw "Task '$TaskId' not found."
}

$failureId = "failure-{0}" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff'))
$failureRecord = [pscustomobject]@{
  id = $failureId
  task_id = $TaskId
  failure_type = $FailureType
  summary = $Summary
  source_check_id = $SourceCheckId
  details = $Details
  status = 'open'
  created_at = Get-IsoNow
  resolved_at = $null
}

$failurePath = Get-FailureFilePath -RunRoot $state.paths.run_root -FailureId $failureId
Write-JsonFile -Path $failurePath -Data $failureRecord

if ($task) {
  $task.status = 'needs_rework'
  $task.verified = $false
  $task.updated_at = Get-IsoNow
}

if ($state.status -eq 'VERIFYING' -or $state.status -eq 'REVERIFYING' -or $state.status -eq 'READY_TO_FINISH') {
  Assert-ValidTransition -From $state.status -To 'FIXING'
  $state.status = 'FIXING'
}

$state = Recompute-RunState -State $state
Save-RunState -State $state
Sync-TaskFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$failureRecord | ConvertTo-Json -Depth 100
