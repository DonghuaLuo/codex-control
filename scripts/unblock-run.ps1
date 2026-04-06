param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [Parameter(Mandatory = $true)]
  [string]$Reason,
  [ValidateSet('IMPLEMENTING', 'FIXING', 'REVERIFYING')]
  [string]$NextStatus = 'IMPLEMENTING'
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$updatedBlockers = @()
$resolved = $false

foreach ($blocker in @($state.external_blockers)) {
  if (-not ($blocker -is [string]) -and $blocker.reason -eq $Reason -and $blocker.status -eq 'open') {
    $blocker.status = 'resolved'
    $blocker.resolved_at = Get-IsoNow
    $resolved = $true
  }
  $updatedBlockers += $blocker
}

if (-not $resolved) {
  throw "No open blocker found for reason '$Reason'."
}

$state.external_blockers = @($updatedBlockers)

$remainingOpenBlockers = Get-OpenBlockerRecords -State $state
if (@($remainingOpenBlockers).Count -eq 0 -and $state.status -eq 'BLOCKED_EXTERNAL') {
  Assert-ValidTransition -From $state.status -To $NextStatus
  $state.status = $NextStatus
}

$state = Recompute-RunState -State $state
Save-RunState -State $state
Sync-TaskFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$state | ConvertTo-Json -Depth 100
