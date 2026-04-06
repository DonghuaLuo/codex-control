Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexControlRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-RepoRoot {
  $override = $env:CODEX_CONTROL_REPO_ROOT
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    return (Resolve-Path $override).Path
  }

  $controllerRoot = Get-CodexControlRoot
  if (Test-Path (Join-Path $controllerRoot '.git')) {
    return $controllerRoot
  }

  return (Resolve-Path (Join-Path $controllerRoot '..')).Path
}

function Get-ActiveRunPointerPath {
  return Join-Path (Get-CodexControlRoot) 'active-run.json'
}

function Get-TaskRegistryPath {
  return Join-Path (Get-CodexControlRoot) 'task-registry.json'
}

function Get-DefaultProfilePath {
  $controllerRoot = Get-CodexControlRoot
  $candidates = @(
    'profiles\default.json'
    'profiles\default-gated.json'
  )

  foreach ($relativePath in $candidates) {
    $candidatePath = Join-Path $controllerRoot $relativePath
    if (Test-Path $candidatePath) {
      return $candidatePath
    }
  }

  throw 'No default codex-control profile found.'
}

function Read-Utf8Text {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $raw = Get-Content -Raw -Encoding UTF8 $Path
  if ($null -eq $raw) {
    return ''
  }
  return $raw.TrimStart([char]0xFEFF)
}

function Write-Utf8Text {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Text
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $lastError = $null
  for ($attempt = 1; $attempt -le 10; $attempt += 1) {
    try {
      [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
      return
    } catch {
      $lastError = $_
      Start-Sleep -Milliseconds (50 * $attempt)
    }
  }

  throw $lastError
}

function Read-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return Read-Utf8Text -Path $Path | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [object]$Data
  )

  $json = $Data | ConvertTo-Json -Depth 100
  Write-Utf8Text -Path $Path -Text $json
}

function Get-IsoNow {
  return [DateTimeOffset]::Now.ToString('o')
}

function Resolve-RunStatePath {
  param(
    [string]$RunId,
    [string]$RunStatePath
  )

  if ($RunStatePath) {
    return (Resolve-Path $RunStatePath).Path
  }

  if ($RunId) {
    return Join-Path (Join-Path (Get-CodexControlRoot) 'runs') (Join-Path $RunId 'current-run.json')
  }

  $pointerPath = Get-ActiveRunPointerPath
  if (-not (Test-Path $pointerPath)) {
    throw 'No active run pointer found.'
  }

  $pointer = Read-JsonFile -Path $pointerPath
  if (-not $pointer.run_state_path) {
    throw 'Active run pointer does not contain run_state_path.'
  }

  return $pointer.run_state_path
}

function Get-RunPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot
  )

  return [pscustomobject]@{
    run_root = $RunRoot
    tasks_root = Join-Path $RunRoot 'tasks'
    assignments_root = Join-Path $RunRoot 'assignments'
    failures_root = Join-Path $RunRoot 'failures'
    artifacts_root = Join-Path $RunRoot 'artifacts'
    checks_root = Join-Path (Join-Path $RunRoot 'artifacts') 'checks'
    agent_outputs_root = Join-Path $RunRoot 'agent-outputs'
    notes_root = Join-Path $RunRoot 'notes'
  }
}

function Get-TaskFilePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$TaskId
  )

  return Join-Path (Join-Path $RunRoot 'tasks') "$TaskId.json"
}

function Get-FailureFilePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$FailureId
  )

  return Join-Path (Join-Path $RunRoot 'failures') "$FailureId.json"
}

function Get-AssignmentFilePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$AssignmentId
  )

  return Join-Path (Join-Path $RunRoot 'assignments') "$AssignmentId.json"
}

function Normalize-RunState {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  if (-not ($State.PSObject.Properties.Name -contains 'external_blockers')) {
    $State | Add-Member -NotePropertyName external_blockers -NotePropertyValue @() -Force
  }
  if (-not ($State.PSObject.Properties.Name -contains 'closeout')) {
    $State | Add-Member -NotePropertyName closeout -NotePropertyValue $null -Force
  }
  if (-not ($State.PSObject.Properties.Name -contains 'task_identity')) {
    $State | Add-Member -NotePropertyName task_identity -NotePropertyValue $null -Force
  }
  if (-not ($State.PSObject.Properties.Name -contains 'prompt')) {
    $State | Add-Member -NotePropertyName prompt -NotePropertyValue $null -Force
  }
  if (-not ($State.PSObject.Properties.Name -contains 'assignments')) {
    $State | Add-Member -NotePropertyName assignments -NotePropertyValue @() -Force
  }
  if ($State.paths -and -not ($State.paths.PSObject.Properties.Name -contains 'assignments_root')) {
    $State.paths | Add-Member -NotePropertyName assignments_root -NotePropertyValue (Join-Path $State.paths.run_root 'assignments') -Force
  }
  if ($State.paths -and -not ($State.paths.PSObject.Properties.Name -contains 'agent_outputs_root')) {
    $State.paths | Add-Member -NotePropertyName agent_outputs_root -NotePropertyValue (Join-Path $State.paths.run_root 'agent-outputs') -Force
  }

  return $State
}

function Load-RunState {
  param(
    [string]$RunId,
    [string]$RunStatePath
  )

  $resolved = Resolve-RunStatePath -RunId $RunId -RunStatePath $RunStatePath
  $state = Read-JsonFile -Path $resolved
  return Normalize-RunState -State $state
}

function Save-RunState {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  Write-JsonFile -Path $State.paths.run_state_path -Data $State
}

function Append-Utf8Line {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [AllowEmptyString()]
    [string]$Line = ''
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $writer = [System.IO.StreamWriter]::new($Path, $true, $utf8NoBom)
  try {
    $writer.WriteLine($Line)
  } finally {
    $writer.Dispose()
  }
}

function Read-TaskRegistry {
  $path = Get-TaskRegistryPath
  if (-not (Test-Path $path)) {
    return [pscustomobject]@{
      version = 1
      tasks = @()
    }
  }

  return Read-JsonFile -Path $path
}

function Write-TaskRegistry {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Registry
  )

  Write-JsonFile -Path (Get-TaskRegistryPath) -Data $Registry
}

function Get-TaskRegistryRecord {
  param(
    [string]$TaskName = '',
    [string]$TaskSlug = ''
  )

  $registry = Read-TaskRegistry

  if (-not [string]::IsNullOrWhiteSpace($TaskSlug)) {
    $entry = @($registry.tasks | Where-Object { $_.task_slug -eq $TaskSlug }) | Select-Object -First 1
    if ($null -ne $entry) {
      return $entry
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($TaskName)) {
    return @($registry.tasks | Where-Object { $_.task_name -eq $TaskName }) | Select-Object -First 1
  }

  return $null
}

function Convert-ToTaskSlug {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TaskName
  )

  $slug = ($TaskName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return ('task-' + ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')))
  }
  return $slug
}

function Sync-TaskRegistryFromRun {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  if ($null -eq $State.task_identity) {
    return
  }

  $registry = Read-TaskRegistry
  $taskSlug = $State.task_identity.task_slug
  $taskName = $State.task_identity.task_name
  $entry = @($registry.tasks | Where-Object { $_.task_slug -eq $taskSlug }) | Select-Object -First 1

  if ($null -eq $entry) {
    $entry = [pscustomobject]@{
      task_name = $taskName
      task_slug = $taskSlug
      created_at = Get-IsoNow
      updated_at = Get-IsoNow
      latest_run_id = $State.run_id
      active_run_id = $(if ($State.status -in (Get-TerminalRunStatuses)) { $null } else { $State.run_id })
      latest_status = $State.status
      latest_objective = $State.objective
      latest_prompt = $State.prompt
      open_failures = @($State.open_failures).Count
      open_blockers = @($State.external_blockers).Count
      run_history = @($State.run_id)
      runs = @()
    }
    $registry.tasks = @($registry.tasks) + @($entry)
  } else {
    $history = @($entry.run_history)
    if (-not ($history -contains $State.run_id)) {
      $entry.run_history = @($history + @($State.run_id))
    }
    if (-not ($entry.PSObject.Properties.Name -contains 'latest_prompt')) {
      $entry | Add-Member -NotePropertyName latest_prompt -NotePropertyValue $null -Force
    }
    $entry.task_name = $taskName
    $entry.updated_at = Get-IsoNow
    $entry.latest_run_id = $State.run_id
    $entry.latest_status = $State.status
    $entry.latest_objective = $State.objective
    $entry.latest_prompt = $State.prompt
    $entry.open_failures = @($State.open_failures).Count
    $entry.open_blockers = @($State.external_blockers).Count
    $entry.active_run_id = $(if ($State.status -in (Get-TerminalRunStatuses)) { $null } else { $State.run_id })
    if (-not ($entry.PSObject.Properties.Name -contains 'runs')) {
      $entry | Add-Member -NotePropertyName runs -NotePropertyValue @() -Force
    }
  }

  $runSummary = [pscustomobject]@{
    run_id = $State.run_id
    status = $State.status
    objective = $State.objective
    prompt = $State.prompt
    updated_at = $State.timestamps.updated_at
    created_at = $State.timestamps.created_at
    completed_at = $State.timestamps.completed_at
    run_state_path = $State.paths.run_state_path
  }
  $runs = @()
  foreach ($existing in @($entry.runs)) {
    if ($existing.run_id -ne $State.run_id) {
      $runs += $existing
    }
  }
  $runs += $runSummary
  $entry.runs = @($runs | Sort-Object updated_at -Descending)

  Write-TaskRegistry -Registry $registry
}

function Set-ActiveRunPointer {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  $pointer = [pscustomobject]@{
    run_id = $State.run_id
    run_state_path = $State.paths.run_state_path
    status = $State.status
    updated_at = Get-IsoNow
  }

  Write-JsonFile -Path (Get-ActiveRunPointerPath) -Data $pointer
}

function Get-TerminalRunStatuses {
  return @('FINISHED', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
}

function Resolve-RepoPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return (Join-Path (Get-RepoRoot) $Path)
}

function Resolve-CommandForExecution {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Command
  )

  if ($Command.Length -eq 0) {
    throw 'Command cannot be empty.'
  }

  if ($Command[0] -ieq 'rtk') {
    if ($Command.Length -lt 2) {
      throw "Wrapper command 'rtk' requires at least one delegated command."
    }

    $Command = @($Command[1..($Command.Length - 1)])
  }

  $commandName = [string]$Command[0]
  $remainingArgs = if ($Command.Length -gt 1) {
    @($Command[1..($Command.Length - 1)])
  } else {
    @()
  }

  if ($commandName -ieq 'pnpm') {
    $forwardedArgs = @()
    foreach ($arg in $remainingArgs) {
      $escaped = ([string]$arg).Replace("'", "''")
      $forwardedArgs += ("'{0}'" -f $escaped)
    }

    $commandText = if ($forwardedArgs.Count -gt 0) {
      "& pnpm @({0}); exit `$LASTEXITCODE" -f ($forwardedArgs -join ', ')
    } else {
      "& pnpm; exit `$LASTEXITCODE"
    }

    return @(
      'powershell.exe'
      '-NoProfile'
      '-ExecutionPolicy'
      'Bypass'
      '-Command'
      $commandText
    )
  }

  if ($commandName -ieq 'codex') {
    foreach ($preferred in @('codex.cmd', 'codex.exe', 'codex')) {
      $resolved = Get-Command -ErrorAction SilentlyContinue $preferred | Select-Object -First 1
      if ($null -eq $resolved) {
        continue
      }

      $resolvedPath = $resolved.Path
      if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = $resolved.Source
      }
      if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
        return @($resolvedPath) + $remainingArgs
      }
    }
  }

  if (-not [System.IO.Path]::IsPathRooted($commandName)) {
    $directResolution = Get-Command -ErrorAction SilentlyContinue $commandName | Select-Object -First 1
    if ($null -ne $directResolution) {
      $directPath = $directResolution.Path
      if ([string]::IsNullOrWhiteSpace($directPath)) {
        $directPath = $directResolution.Source
      }

      if (
        $directResolution.CommandType -eq 'ExternalScript' -and
        -not [string]::IsNullOrWhiteSpace($directPath) -and
        $directPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)
      ) {
        return @(
          'powershell.exe'
          '-NoProfile'
          '-ExecutionPolicy'
          'Bypass'
          '-File'
          $directPath
        ) + $remainingArgs
      }
    }

    $candidates = @($commandName)
    if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($commandName))) {
      $candidates = @(
        "$commandName.cmd"
        "$commandName.exe"
        $commandName
      )
    }

    foreach ($candidate in $candidates) {
      $resolved = Get-Command -ErrorAction SilentlyContinue $candidate | Select-Object -First 1
      if ($null -eq $resolved) {
        continue
      }

      $resolvedPath = $resolved.Path
      if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = $resolved.Source
      }
      if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
        $Command[0] = $resolvedPath
        break
      }
    }
  }

  return @($Command)
}

function Get-AllowedTransitions {
  return @{
    PLANNING = @('IMPLEMENTING', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
    IMPLEMENTING = @('VERIFYING', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
    VERIFYING = @('FIXING', 'READY_TO_FINISH', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
    FIXING = @('REVERIFYING', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
    REVERIFYING = @('FIXING', 'READY_TO_FINISH', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
    READY_TO_FINISH = @('FINISHED', 'FIXING', 'BLOCKED_EXTERNAL', 'SUPERSEDED')
    FINISHED = @()
    SUPERSEDED = @()
    BLOCKED_EXTERNAL = @('IMPLEMENTING', 'FIXING', 'REVERIFYING')
  }
}

function Assert-ValidTransition {
  param(
    [Parameter(Mandatory = $true)]
    [string]$From,
    [Parameter(Mandatory = $true)]
    [string]$To
  )

  if ($From -eq $To) {
    return
  }

  $map = Get-AllowedTransitions
  $allowed = @($map[$From])
  if (-not ($allowed -contains $To)) {
    throw "Invalid run status transition: $From -> $To"
  }
}

function Sync-TaskFiles {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  foreach ($task in @($State.tasks)) {
    $taskPath = Get-TaskFilePath -RunRoot $State.paths.run_root -TaskId $task.id
    Write-JsonFile -Path $taskPath -Data $task
  }
}

function Sync-AssignmentFiles {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  foreach ($assignment in @($State.assignments)) {
    $assignmentPath = Get-AssignmentFilePath -RunRoot $State.paths.run_root -AssignmentId $assignment.id
    Write-JsonFile -Path $assignmentPath -Data $assignment
  }
}

function Get-OpenFailureRecords {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  $failuresRoot = $State.paths.failures_root
  if (-not (Test-Path $failuresRoot)) {
    return @()
  }

  $records = @()
  foreach ($file in @(Get-ChildItem -File $failuresRoot -Filter *.json)) {
    $record = Read-JsonFile -Path $file.FullName
    if ($record.status -eq 'open') {
      $records += $record
    }
  }
  return @($records)
}

function Get-OpenBlockerRecords {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  $records = @()
  foreach ($blocker in @($State.external_blockers)) {
    if ($blocker -is [string]) {
      $records += [pscustomobject]@{
        id = $blocker
        reason = $blocker
        status = 'open'
      }
      continue
    }

    if ($blocker.status -eq 'open') {
      $records += $blocker
    }
  }
  return @($records)
}

function Recompute-RunState {
  param(
    [Parameter(Mandatory = $true)]
    [object]$State
  )

  $requiredTasks = @($State.tasks | Where-Object { $_.required -eq $true })
  $requiredChecks = @($State.required_checks | Where-Object { $_.required -eq $true })
  $openFailures = Get-OpenFailureRecords -State $State
  $openBlockers = Get-OpenBlockerRecords -State $State

  $allRequiredTasksDone = @($requiredTasks | Where-Object { $_.status -ne 'done' }).Count -eq 0
  $allRequiredTasksVerified = @($requiredTasks | Where-Object { $_.verified -ne $true }).Count -eq 0
  $allRequiredChecksPassed = @($requiredChecks | Where-Object { $_.status -ne 'pass' }).Count -eq 0
  $noOpenFailures = @($openFailures).Count -eq 0
  $noExternalBlockers = @($openBlockers).Count -eq 0
  $statusReady = $State.status -in @('READY_TO_FINISH', 'FINISHED')

  $State.open_failures = @($openFailures | ForEach-Object { $_.id })
  $State.final_gate = [pscustomobject]@{
    all_required_tasks_done = $allRequiredTasksDone
    all_required_tasks_verified = $allRequiredTasksVerified
    all_required_checks_passed = $allRequiredChecksPassed
    no_open_failures = $noOpenFailures
    no_external_blockers = $noExternalBlockers
    status_ready = $statusReady
  }
  $State.can_finish = $allRequiredTasksDone -and $allRequiredTasksVerified -and $allRequiredChecksPassed -and $noOpenFailures -and $noExternalBlockers -and $statusReady
  $State.timestamps.updated_at = Get-IsoNow
  return $State
}

function Invoke-LoggedCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Command,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$StdoutPath,
    [Parameter(Mandatory = $true)]
    [string]$StderrPath,
    [int]$TimeoutSec = 0
  )

  $stdoutDirectory = Split-Path -Parent $StdoutPath
  if (-not [string]::IsNullOrWhiteSpace($stdoutDirectory)) {
    New-Item -ItemType Directory -Force -Path $stdoutDirectory | Out-Null
  }

  # In this Windows sandbox, redirecting pnpm's stdio can cause downstream tools such as
  # esbuild to fail with spawn EPERM. Run pnpm with inherited console handles instead.
  if ($Command.Length -gt 0 -and $Command[0] -ieq 'pnpm') {
    $originalLocation = Get-Location
    $stderrText = ''
    Write-Utf8Text -Path $StdoutPath -Text 'Command output was emitted directly to the console.'
    Write-Utf8Text -Path $StderrPath -Text ''

    try {
      Set-Location -LiteralPath $WorkingDirectory
      if ($Command.Length -gt 1) {
        & $Command[0] @($Command[1..($Command.Length - 1)])
      } else {
        & $Command[0]
      }
      $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } catch {
      $exitCode = 1
      $stderrText = ($_ | Out-String).Trim()
      if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Utf8Text -Path $StderrPath -Text $stderrText
      }
    } finally {
      Set-Location -LiteralPath $originalLocation
    }

    return [pscustomobject]@{
      exit_code = $exitCode
      stdout = ''
      stderr = $stderrText
      timed_out = $false
    }
  }

  $resolvedCommand = Resolve-CommandForExecution -Command $Command
  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = $resolvedCommand[0]
  if ($resolvedCommand.Length -gt 1) {
    $quotedArguments = @()
    foreach ($argument in $resolvedCommand[1..($resolvedCommand.Length - 1)]) {
      $value = [string]$argument
      if ($value -match '[\s"]') {
        $escaped = $value.Replace('"', '\"')
        $quotedArguments += ('"' + $escaped + '"')
      } else {
        $quotedArguments += $value
      }
    }
    $processInfo.Arguments = ($quotedArguments -join ' ')
  }
  $processInfo.WorkingDirectory = $WorkingDirectory
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processInfo

  [void]$process.Start()
  if ($TimeoutSec -gt 0) {
    $exited = $process.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
      try { $process.Kill() } catch {}
      Write-Utf8Text -Path $StdoutPath -Text ''
      Write-Utf8Text -Path $StderrPath -Text "Process timed out after $TimeoutSec seconds."
      return [pscustomobject]@{
        exit_code = 124
        stdout = ''
        stderr = "Process timed out after $TimeoutSec seconds."
        timed_out = $true
      }
    }
  } else {
    $process.WaitForExit()
  }
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()

  Write-Utf8Text -Path $StdoutPath -Text $stdout
  Write-Utf8Text -Path $StderrPath -Text $stderr

  return [pscustomobject]@{
    exit_code = $process.ExitCode
    stdout = $stdout
    stderr = $stderr
    timed_out = $false
  }
}

function Invoke-LoggedCommandWithInput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Command,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$StdoutPath,
    [Parameter(Mandatory = $true)]
    [string]$StderrPath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$InputText,
    [int]$TimeoutSec = 0,
    [string]$HeartbeatLabel = ''
  )

  $stdoutDirectory = Split-Path -Parent $StdoutPath
  if (-not [string]::IsNullOrWhiteSpace($stdoutDirectory)) {
    New-Item -ItemType Directory -Force -Path $stdoutDirectory | Out-Null
  }

  $resolvedCommand = Resolve-CommandForExecution -Command $Command
  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = $resolvedCommand[0]
  if ($resolvedCommand.Length -gt 1) {
    $quotedArguments = @()
    foreach ($argument in $resolvedCommand[1..($resolvedCommand.Length - 1)]) {
      $value = [string]$argument
      if ($value -match '[\s"]') {
        $escaped = $value.Replace('"', '\"')
        $quotedArguments += ('"' + $escaped + '"')
      } else {
        $quotedArguments += $value
      }
    }
    $processInfo.Arguments = ($quotedArguments -join ' ')
  }
  $processInfo.WorkingDirectory = $WorkingDirectory
  $processInfo.RedirectStandardInput = $true
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processInfo

  [void]$process.Start()
  $process.StandardInput.Write($InputText)
  $process.StandardInput.Close()
  $startedAt = Get-Date
  $lastHeartbeatAt = $startedAt
  $heartbeatEverySec = 10

  while (-not $process.HasExited) {
    $waited = $process.WaitForExit(1000)
    if ($waited) {
      break
    }

    $elapsedSec = [int]((Get-Date) - $startedAt).TotalSeconds
    if ($TimeoutSec -gt 0 -and $elapsedSec -ge $TimeoutSec) {
      try { $process.Kill() } catch {}
      Write-Utf8Text -Path $StdoutPath -Text ''
      Write-Utf8Text -Path $StderrPath -Text "Process timed out after $TimeoutSec seconds."
      return [pscustomobject]@{
        exit_code = 124
        stdout = ''
        stderr = "Process timed out after $TimeoutSec seconds."
        timed_out = $true
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($HeartbeatLabel)) {
      $heartbeatDelta = [int]((Get-Date) - $lastHeartbeatAt).TotalSeconds
      if ($heartbeatDelta -ge $heartbeatEverySec) {
        Write-Host "[cc] $HeartbeatLabel still running (${elapsedSec}s elapsed)..."
        $lastHeartbeatAt = Get-Date
      }
    }
  }

  $process.WaitForExit()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()

  Write-Utf8Text -Path $StdoutPath -Text $stdout
  Write-Utf8Text -Path $StderrPath -Text $stderr

  return [pscustomobject]@{
    exit_code = $process.ExitCode
    stdout = $stdout
    stderr = $stderr
    timed_out = $false
  }
}

function Invoke-StreamingCommandWithInput {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Command,
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,
    [Parameter(Mandatory = $true)]
    [string]$StdoutPath,
    [Parameter(Mandatory = $true)]
    [string]$StderrPath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$InputText,
    [int]$TimeoutSec = 0,
    [string]$HeartbeatLabel = '',
    [scriptblock]$OnStdoutLine = $null,
    [scriptblock]$OnStderrLine = $null
  )

  $stdoutDirectory = Split-Path -Parent $StdoutPath
  if (-not [string]::IsNullOrWhiteSpace($stdoutDirectory)) {
    New-Item -ItemType Directory -Force -Path $stdoutDirectory | Out-Null
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $stdoutWriter = [System.IO.StreamWriter]::new($StdoutPath, $false, $utf8NoBom)
  $stderrWriter = [System.IO.StreamWriter]::new($StderrPath, $false, $utf8NoBom)

  $resolvedCommand = Resolve-CommandForExecution -Command $Command
  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = $resolvedCommand[0]
  if ($resolvedCommand.Length -gt 1) {
    $quotedArguments = @()
    foreach ($argument in $resolvedCommand[1..($resolvedCommand.Length - 1)]) {
      $value = [string]$argument
      if ($value -match '[\s"]') {
        $escaped = $value.Replace('"', '\"')
        $quotedArguments += ('"' + $escaped + '"')
      } else {
        $quotedArguments += $value
      }
    }
    $processInfo.Arguments = ($quotedArguments -join ' ')
  }
  $processInfo.WorkingDirectory = $WorkingDirectory
  $processInfo.RedirectStandardInput = $true
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processInfo

  [void]$process.Start()
  $process.StandardInput.Write($InputText)
  $process.StandardInput.Close()

  $startedAt = Get-Date
  $lastHeartbeatAt = $startedAt
  $heartbeatEverySec = 10
  $stdoutDone = $false
  $stderrDone = $false
  $stdoutTask = $process.StandardOutput.ReadLineAsync()
  $stderrTask = $process.StandardError.ReadLineAsync()

  try {
    while (-not $process.HasExited -or -not $stdoutDone -or -not $stderrDone) {
      $hadActivity = $false

      if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
        $line = $stdoutTask.Result
        if ($null -eq $line) {
          $stdoutDone = $true
        } else {
          $stdoutWriter.WriteLine($line)
          $stdoutWriter.Flush()
          $hadActivity = $true
          if ($OnStdoutLine) {
            & $OnStdoutLine $line
          }
          $stdoutTask = $process.StandardOutput.ReadLineAsync()
        }
      }

      if (-not $stderrDone -and $stderrTask.IsCompleted) {
        $line = $stderrTask.Result
        if ($null -eq $line) {
          $stderrDone = $true
        } else {
          $stderrWriter.WriteLine($line)
          $stderrWriter.Flush()
          $hadActivity = $true
          if ($OnStderrLine) {
            & $OnStderrLine $line
          }
          $stderrTask = $process.StandardError.ReadLineAsync()
        }
      }

      if ($process.HasExited -and $stdoutDone -and $stderrDone) {
        break
      }

      $elapsedSec = [int]((Get-Date) - $startedAt).TotalSeconds
      if ($TimeoutSec -gt 0 -and $elapsedSec -ge $TimeoutSec) {
        try { $process.Kill() } catch {}
        $stderrWriter.WriteLine("Process timed out after $TimeoutSec seconds.")
        $stderrWriter.Flush()
        return [pscustomobject]@{
          exit_code = 124
          stdout = Read-Utf8Text -Path $StdoutPath
          stderr = Read-Utf8Text -Path $StderrPath
          timed_out = $true
        }
      }

      if (-not $hadActivity) {
        Start-Sleep -Milliseconds 200
      }

      if (-not [string]::IsNullOrWhiteSpace($HeartbeatLabel)) {
        $heartbeatDelta = [int]((Get-Date) - $lastHeartbeatAt).TotalSeconds
        if ($heartbeatDelta -ge $heartbeatEverySec) {
          Write-Host "[cc] $HeartbeatLabel still running (${elapsedSec}s elapsed)..."
          $lastHeartbeatAt = Get-Date
        }
      }
    }
  } finally {
    $stdoutWriter.Dispose()
    $stderrWriter.Dispose()
  }

  $process.WaitForExit()

  return [pscustomobject]@{
    exit_code = $process.ExitCode
    stdout = Read-Utf8Text -Path $StdoutPath
    stderr = Read-Utf8Text -Path $StderrPath
    timed_out = $false
  }
}
