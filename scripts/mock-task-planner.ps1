param(
  [Alias('o')]
  [string]$OutputLastMessage = '',
  [Alias('cd')]
  [string]$WorkingDirectory = '',
  [switch]$json,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$plan = [pscustomobject]@{
  tasks = @(
    [pscustomobject]@{
      id = 'analyze-request'
      title = 'Analyze Request'
      description = 'Analyze the request and lock the execution boundary.'
      required = $true
      owner_hint = 'main-agent'
      depends_on = @()
    },
    [pscustomobject]@{
      id = 'implement-workstream'
      title = 'Implement Workstream'
      description = 'Implement the main code and script changes required by the request.'
      required = $true
      owner_hint = 'worker-agent'
      depends_on = @('analyze-request')
      parallel_group = 'implementation'
    },
    [pscustomobject]@{
      id = 'verify-and-fix'
      title = 'Verify And Fix'
      description = 'Run verification, then fix and retest until checks pass.'
      required = $true
      owner_hint = 'main-agent'
      depends_on = @('implement-workstream')
    }
  )
}

$jsonText = $plan | ConvertTo-Json -Compress -Depth 20
if ($OutputLastMessage) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($OutputLastMessage, $jsonText, $utf8NoBom)
}

Write-Output $jsonText
