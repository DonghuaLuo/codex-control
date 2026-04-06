param(
  [Alias('o')]
  [string]$OutputLastMessage = '',
  [Alias('cd')]
  [string]$WorkingDirectory = '',
  [switch]$json,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$ErrorActionPreference = 'Stop'

$lastMessagePath = $OutputLastMessage

$stdinText = [Console]::In.ReadToEnd()
$message = if ($stdinText -match 'Finish gate rejected') {
  if ($stdinText -match '(?im)Run state:\s*(.+current-run\.json)') {
    $runStatePath = $Matches[1].Trim()
    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    $updateScript = Join-Path $PSScriptRoot 'update-state.ps1'
    $verifyScript = Join-Path $PSScriptRoot 'verify.ps1'
    $runState = Get-Content -Raw -Encoding UTF8 $runStatePath | ConvertFrom-Json

    foreach ($task in @($runState.tasks)) {
      & $updateScript -RunStatePath $runStatePath -TaskId $task.id -TaskStatus done -TaskVerified true | Out-Null
    }
    & $updateScript -RunStatePath $runStatePath -Status VERIFYING | Out-Null
    & $verifyScript -RunStatePath $runStatePath | Out-Null
  }
  'mock codex continued after gate rejection'
} else {
  'mock codex initial final'
}

if ($lastMessagePath) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($lastMessagePath, $message, $utf8NoBom)
}

$event = [pscustomobject]@{
  type = 'assistant_message'
  role = 'assistant'
  message = $message
}

$event | ConvertTo-Json -Compress -Depth 20
