param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [string]$Status = '',
  [string]$TaskId = '',
  [string]$TaskStatus = '',
  [string]$TaskVerified = '',
  [string]$ProfilePath = '',
  [string]$AddExternalBlocker = '',
  [string]$RemoveExternalBlocker = '',
  [string]$ResolveFailureId = '',
  [switch]$ResolveAllFailures
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath

if ($TaskId) {
  $task = @($state.tasks | Where-Object { $_.id -eq $TaskId }) | Select-Object -First 1
  if (-not $task) {
    throw "Task '$TaskId' not found."
  }

  if ($TaskStatus) {
    $task.status = $TaskStatus
  }
  if (-not [string]::IsNullOrWhiteSpace($TaskVerified)) {
    switch ($TaskVerified.ToLowerInvariant()) {
      'true' { $task.verified = $true; break }
      'false' { $task.verified = $false; break }
      '1' { $task.verified = $true; break }
      '0' { $task.verified = $false; break }
      default { throw "Unsupported TaskVerified value '$TaskVerified'. Use true/false/1/0." }
    }
  }
  $task.updated_at = Get-IsoNow
}

if ($ProfilePath) {
  $profileResolved = Resolve-Path $ProfilePath
  $profile = Read-JsonFile -Path $profileResolved
  $state.profile = [pscustomobject]@{
    id = $profile.profile_id
    name = $profile.name
    path = $profileResolved.Path
  }
  $state.required_checks = @(
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
}

if ($AddExternalBlocker) {
  $state.external_blockers = @($state.external_blockers) + @($AddExternalBlocker)
}

if ($RemoveExternalBlocker) {
  $state.external_blockers = @($state.external_blockers | Where-Object { $_ -ne $RemoveExternalBlocker })
}

if ($ResolveAllFailures) {
  foreach ($file in @(Get-ChildItem -File $state.paths.failures_root -Filter *.json)) {
    $failure = Read-JsonFile -Path $file.FullName
    if ($failure.status -eq 'open') {
      $failure.status = 'resolved'
      $failure.resolved_at = Get-IsoNow
      Write-JsonFile -Path $file.FullName -Data $failure
    }
  }
}

if ($ResolveFailureId) {
  $failurePath = Get-FailureFilePath -RunRoot $state.paths.run_root -FailureId $ResolveFailureId
  if (-not (Test-Path $failurePath)) {
    throw "Failure '$ResolveFailureId' not found."
  }
  $failure = Read-JsonFile -Path $failurePath
  $failure.status = 'resolved'
  $failure.resolved_at = Get-IsoNow
  Write-JsonFile -Path $failurePath -Data $failure
}

if ($Status) {
  Assert-ValidTransition -From $state.status -To $Status
  $state.status = $Status
}

$state = Recompute-RunState -State $state
Save-RunState -State $state
Sync-TaskFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$state | ConvertTo-Json -Depth 100
