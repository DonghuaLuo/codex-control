param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [Parameter(Mandatory = $true)]
  [string]$Reason,
  [string]$Evidence = '',
  [string]$NextRequiredAction = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$blockerId = "blocker-{0}" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff'))

$blocker = [pscustomobject]@{
  id = $blockerId
  reason = $Reason
  evidence = $Evidence
  next_required_action = $NextRequiredAction
  status = 'open'
  created_at = Get-IsoNow
  resolved_at = $null
}

$state.external_blockers = @($state.external_blockers) + @($blocker)

if ($state.status -ne 'BLOCKED_EXTERNAL') {
  Assert-ValidTransition -From $state.status -To 'BLOCKED_EXTERNAL'
  $state.status = 'BLOCKED_EXTERNAL'
}

$state = Recompute-RunState -State $state
Save-RunState -State $state
Sync-TaskFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$blocker | ConvertTo-Json -Depth 100
