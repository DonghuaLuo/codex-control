param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [string]$ProfilePath = '',
  [switch]$PersistProfileOverride
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath

if ($ProfilePath) {
  $profileResolved = Resolve-Path $ProfilePath
  $profile = Read-JsonFile -Path $profileResolved
  $checks = @(
    foreach ($check in @($profile.checks)) {
      [pscustomobject]@{
        id = $check.id
        title = $check.title
        required = if ($null -eq $check.required) { $true } else { [bool]$check.required }
        workdir = $check.workdir
        command = @($check.command)
        status = 'pending'
        last_run = $null
      }
    }
  )

  if ($PersistProfileOverride) {
    $state.profile = [pscustomobject]@{
      id = $profile.profile_id
      name = $profile.name
      path = $profileResolved.Path
    }
    $state.required_checks = $checks
  }
} else {
  $checks = @($state.required_checks)
}

if ($state.status -eq 'REVERIFYING') {
  $nextStatus = 'REVERIFYING'
} elseif ($state.status -eq 'FIXING') {
  $nextStatus = 'REVERIFYING'
} elseif ($state.status -eq 'PLANNING') {
  $nextStatus = 'VERIFYING'
} elseif ($state.status -eq 'IMPLEMENTING') {
  $nextStatus = 'VERIFYING'
} else {
  $nextStatus = $state.status
}

if ($state.status -ne $nextStatus) {
  Assert-ValidTransition -From $state.status -To $nextStatus
  $state.status = $nextStatus
}

$checkResults = @()
$hasFailure = $false
$failuresRoot = $state.paths.failures_root

foreach ($check in @($checks)) {
  $startedAt = Get-IsoNow
  $workingDirectory = Resolve-RepoPath -Path $check.workdir
  $stdoutPath = Join-Path $state.paths.checks_root "$($check.id).stdout.log"
  $stderrPath = Join-Path $state.paths.checks_root "$($check.id).stderr.log"

  $executionResult = Invoke-LoggedCommand -Command @($check.command) -WorkingDirectory $workingDirectory -StdoutPath $stdoutPath -StderrPath $stderrPath
  $execution = @($executionResult | Where-Object { $_.PSObject.Properties.Name -contains 'exit_code' }) | Select-Object -Last 1
  if ($null -eq $execution) {
    throw "Check '$($check.id)' did not return an execution result object."
  }
  $endedAt = Get-IsoNow

  $status = if ($execution.exit_code -eq 0) { 'pass' } else { 'fail' }
  if ($status -eq 'fail' -and $check.required) {
    $hasFailure = $true
  }

  $openVerificationFailures = @()
  foreach ($failureFile in @(Get-ChildItem -File $failuresRoot -Filter *.json)) {
    $failureRecord = Read-JsonFile -Path $failureFile.FullName
    if ($failureRecord.status -eq 'open' -and $failureRecord.failure_type -eq 'verification_failure' -and $failureRecord.source_check_id -eq $check.id) {
      $openVerificationFailures += $failureRecord
    }
  }

  if ($status -eq 'fail' -and $check.required -and @($openVerificationFailures).Count -eq 0) {
    $failureId = "failure-{0}" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff'))
    $failureRecord = [pscustomobject]@{
      id = $failureId
      task_id = ''
      failure_type = 'verification_failure'
      summary = "Required check '$($check.id)' failed"
      source_check_id = $check.id
      details = "stdout: $stdoutPath`nstderr: $stderrPath"
      status = 'open'
      auto_generated = $true
      created_at = Get-IsoNow
      resolved_at = $null
    }
    Write-JsonFile -Path (Join-Path $failuresRoot "$failureId.json") -Data $failureRecord
  }

  if ($status -eq 'pass' -and @($openVerificationFailures).Count -gt 0) {
    foreach ($openFailure in $openVerificationFailures) {
      $openFailure.status = 'resolved'
      $openFailure.resolved_at = Get-IsoNow
      Write-JsonFile -Path (Join-Path $failuresRoot "$($openFailure.id).json") -Data $openFailure
    }
  }

  $result = [pscustomobject]@{
    id = $check.id
    title = $check.title
    required = [bool]$check.required
    workdir = $check.workdir
    command = @($check.command)
    status = $status
    last_run = [pscustomobject]@{
      started_at = $startedAt
      ended_at = $endedAt
      exit_code = $execution.exit_code
      stdout_path = $stdoutPath
      stderr_path = $stderrPath
    }
  }
  $checkResults += $result

  $artifactPath = Join-Path $state.paths.checks_root "$($check.id).result.json"
  Write-JsonFile -Path $artifactPath -Data $result
}

$state.required_checks = @($checkResults)
$state = Recompute-RunState -State $state
$autoOpenFailures = @($state.open_failures)

if (-not $hasFailure -and $state.final_gate.all_required_tasks_done -and $state.final_gate.all_required_tasks_verified -and $state.final_gate.no_open_failures -and $state.final_gate.no_external_blockers) {
  Assert-ValidTransition -From $state.status -To 'READY_TO_FINISH'
  $state.status = 'READY_TO_FINISH'
  $state = Recompute-RunState -State $state
}

Save-RunState -State $state
Sync-TaskFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$report = [pscustomobject]@{
  run_id = $state.run_id
  status = $state.status
  has_failure = $hasFailure
  auto_open_failures = @($autoOpenFailures)
  checks = @($state.required_checks)
  can_finish = $state.can_finish
}

$report | ConvertTo-Json -Depth 100

if ($hasFailure) {
  exit 1
}
