param(
  [Alias('o')]
  [string]$OutputLastMessage = '',
  [Alias('cd')]
  [string]$WorkingDirectory = '',
  [switch]$json,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

Write-Error 'mock codex forced failure'
exit 1
