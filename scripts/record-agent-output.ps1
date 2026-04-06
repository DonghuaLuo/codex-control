param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [string]$AgentName = '',
  [ValidateSet('main-agent', 'worker-agent')]
  [string]$AgentRole = 'worker-agent',
  [string]$TaskId = '',
  [Alias('Title', 'Message')]
  [string]$Summary = '',
  [Alias('Body')]
  [string]$Content = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
New-Item -ItemType Directory -Force -Path $state.paths.agent_outputs_root | Out-Null

if ([string]::IsNullOrWhiteSpace($AgentName)) {
  if ($AgentRole -eq 'main-agent') {
    $AgentName = 'main-agent'
  } elseif (-not [string]::IsNullOrWhiteSpace($TaskId)) {
    $AgentName = "worker-$TaskId"
  } else {
    $AgentName = $AgentRole
  }
}

if ([string]::IsNullOrWhiteSpace($Summary) -and -not [string]::IsNullOrWhiteSpace($Content)) {
  $normalizedContent = $Content -replace '\r?\n', ' '
  $Summary = if ($normalizedContent.Length -gt 120) {
    $normalizedContent.Substring(0, 120) + '...'
  } else {
    $normalizedContent
  }
}

if ([string]::IsNullOrWhiteSpace($Content) -and -not [string]::IsNullOrWhiteSpace($Summary)) {
  $Content = $Summary
}

if ([string]::IsNullOrWhiteSpace($Summary) -and [string]::IsNullOrWhiteSpace($Content)) {
  throw 'record-agent-output requires at least one of -Summary/-Content (or compatible aliases such as -Message, -Title, -Body).'
}

$recordId = "agent-output-{0}" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff'))
$recordPath = Join-Path $state.paths.agent_outputs_root "$recordId.json"

$record = [pscustomobject]@{
  id = $recordId
  agent_name = $AgentName
  agent_role = $AgentRole
  task_id = $(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
  summary = $Summary
  content = $Content
  created_at = Get-IsoNow
}

Write-JsonFile -Path $recordPath -Data $record
$record | ConvertTo-Json -Depth 100
