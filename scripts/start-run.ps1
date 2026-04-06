param(
  [Parameter(Mandatory = $true)]
  [string]$Objective,
  [string]$TaskName = '',
  [string]$PromptText = '',
  [string]$ProfilePath = '',
  [string]$TasksPath = '',
  [string]$RunId = '',
  [string]$ContinueFromRunId = '',
  [switch]$Force
)

. (Join-Path $PSScriptRoot 'common.ps1')

$controllerRoot = Get-CodexControlRoot
$runsRoot = Join-Path $controllerRoot 'runs'
New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null

$pointerPath = Get-ActiveRunPointerPath
if ((Test-Path $pointerPath) -and -not $Force) {
  $pointer = Read-JsonFile -Path $pointerPath
  if ($pointer.status -and $pointer.status -notin @('FINISHED', 'BLOCKED_EXTERNAL')) {
    throw "Active run '$($pointer.run_id)' is still open. Use -Force to replace it."
  }
}

if (-not $RunId) {
  $RunId = "run-{0}" -f ([DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff'))
}
if ([string]::IsNullOrWhiteSpace($TaskName)) {
  $TaskName = $Objective
}
$taskSlug = Convert-ToTaskSlug -TaskName $TaskName

$existingTaskEntry = Get-TaskRegistryRecord -TaskName $TaskName -TaskSlug $taskSlug
if ($null -ne $existingTaskEntry -and -not [string]::IsNullOrWhiteSpace($existingTaskEntry.active_run_id)) {
  $existingActiveRunPath = Join-Path (Join-Path $controllerRoot 'runs') (Join-Path $existingTaskEntry.active_run_id 'current-run.json')
  if (Test-Path $existingActiveRunPath) {
    $existingActiveRun = Load-RunState -RunStatePath $existingActiveRunPath
    if ($existingActiveRun.status -notin (Get-TerminalRunStatuses)) {
      Assert-ValidTransition -From $existingActiveRun.status -To 'SUPERSEDED'
      $existingActiveRun.closeout = [pscustomobject]@{
        reason = 'superseded_by_new_run'
        superseded_by_run_id = $RunId
        closed_from_status = $existingActiveRun.status
        at = Get-IsoNow
      }
      $existingActiveRun.status = 'SUPERSEDED'
      $existingActiveRun.timestamps.completed_at = Get-IsoNow
      $existingActiveRun = Recompute-RunState -State $existingActiveRun
      Save-RunState -State $existingActiveRun
      Sync-TaskFiles -State $existingActiveRun
      Sync-AssignmentFiles -State $existingActiveRun
      Sync-TaskRegistryFromRun -State $existingActiveRun
    }
  }
}

$runRoot = Join-Path $runsRoot $RunId
$paths = Get-RunPaths -RunRoot $runRoot
New-Item -ItemType Directory -Force -Path $paths.run_root, $paths.tasks_root, $paths.assignments_root, $paths.failures_root, $paths.artifacts_root, $paths.checks_root, $paths.agent_outputs_root, $paths.notes_root | Out-Null

if (-not $ProfilePath) {
  $ProfilePath = Get-DefaultProfilePath
}
if (-not $TasksPath) {
  $TasksPath = Join-Path $controllerRoot 'templates\default-tasks.json'
}

$profileResolved = Resolve-Path $ProfilePath
$tasksResolved = Resolve-Path $TasksPath

$profile = Read-JsonFile -Path $profileResolved
$taskTemplate = Read-JsonFile -Path $tasksResolved
$createdAt = Get-IsoNow

$tasks = @()
$assignments = @()
foreach ($task in @($taskTemplate.tasks)) {
  $owner = 'worker-agent'
  if ($task.PSObject.Properties.Name -contains 'owner' -and -not [string]::IsNullOrWhiteSpace($task.owner)) {
    $owner = $task.owner
  } elseif ($task.PSObject.Properties.Name -contains 'owner_hint' -and -not [string]::IsNullOrWhiteSpace($task.owner_hint)) {
    $owner = $task.owner_hint
  }
  $dependsOn = if ($task.PSObject.Properties.Name -contains 'depends_on') { @($task.depends_on) } else { @() }
  $parallelGroup = if ($task.PSObject.Properties.Name -contains 'parallel_group') { $task.parallel_group } else { $null }
  $modules = if ($task.PSObject.Properties.Name -contains 'modules') { @($task.modules) } else { @() }
  $assignmentId = "assignment-$($task.id)"
  $agentName = if ($owner -eq 'main-agent') { 'main-agent' } else { "worker-$($task.id)" }
  $tasks += [pscustomobject]@{
    id = $task.id
    title = $task.title
    description = $task.description
    required = if ($null -eq $task.required) { $true } else { [bool]$task.required }
    owner = $owner
    assignment_id = $assignmentId
    depends_on = @($dependsOn)
    parallel_group = $parallelGroup
    modules = @($modules)
    status = 'pending'
    verified = $false
    updated_at = $createdAt
  }
  $assignments += [pscustomobject]@{
    id = $assignmentId
    agent_name = $agentName
    agent_role = $owner
    task_ids = @($task.id)
    depends_on = @($dependsOn)
    parallel_group = $parallelGroup
    modules = @($modules)
    status = 'pending'
    created_at = $createdAt
    updated_at = $createdAt
  }
}

$requiredChecks = @()
foreach ($check in @($profile.checks)) {
  $requiredChecks += [pscustomobject]@{
    id = $check.id
    title = $check.title
    required = if ($null -eq $check.required) { $true } else { [bool]$check.required }
    workdir = $check.workdir
    command = @($check.command)
    status = 'pending'
    last_run = $null
  }
}

$state = [pscustomobject]@{
  run_id = $RunId
  task_identity = [pscustomobject]@{
    task_name = $TaskName
    task_slug = $taskSlug
    continue_from_run_id = $(if ([string]::IsNullOrWhiteSpace($ContinueFromRunId)) { $null } else { $ContinueFromRunId })
  }
  objective = $Objective
  prompt = $(if ([string]::IsNullOrWhiteSpace($PromptText)) { $null } else { $PromptText })
  status = 'PLANNING'
  can_finish = $false
  profile = [pscustomobject]@{
    id = $profile.profile_id
    name = $profile.name
    path = $profileResolved.Path
  }
  paths = [pscustomobject]@{
    controller_root = $controllerRoot
    repo_root = Get-RepoRoot
    run_root = $paths.run_root
    run_state_path = Join-Path $runRoot 'current-run.json'
    tasks_root = $paths.tasks_root
    assignments_root = $paths.assignments_root
    failures_root = $paths.failures_root
    artifacts_root = $paths.artifacts_root
    checks_root = $paths.checks_root
    agent_outputs_root = $paths.agent_outputs_root
    notes_root = $paths.notes_root
  }
  timestamps = [pscustomobject]@{
    created_at = $createdAt
    updated_at = $createdAt
    completed_at = $null
  }
  tasks = @($tasks)
  assignments = @($assignments)
  required_checks = @($requiredChecks)
  open_failures = @()
  external_blockers = @()
  closeout = $null
  final_gate = [pscustomobject]@{
    all_required_tasks_done = $false
    all_required_tasks_verified = $false
    all_required_checks_passed = $false
    no_open_failures = $true
    no_external_blockers = $true
    status_ready = $false
  }
}

$state = Recompute-RunState -State $state
Save-RunState -State $state
Sync-TaskFiles -State $state
Sync-AssignmentFiles -State $state
Set-ActiveRunPointer -State $state
Sync-TaskRegistryFromRun -State $state

$state | ConvertTo-Json -Depth 100
