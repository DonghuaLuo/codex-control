param(
  [string]$RunId = '',
  [string]$RunStatePath = '',
  [switch]$Detailed
)

. (Join-Path $PSScriptRoot 'common.ps1')

$state = Load-RunState -RunId $RunId -RunStatePath $RunStatePath
$state = Recompute-RunState -State $state
Save-RunState -State $state
Set-ActiveRunPointer -State $state

$openTasks = @($state.tasks | Where-Object { $_.status -ne 'done' })
$assignments = @($state.assignments)
$failedChecks = @($state.required_checks | Where-Object { $_.status -eq 'fail' })
$openFailures = Get-OpenFailureRecords -State $state
$openBlockers = Get-OpenBlockerRecords -State $state
$agentOutputRoot = $state.paths.agent_outputs_root
$agentOutputs = @()
if (Test-Path $agentOutputRoot) {
  foreach ($file in @(Get-ChildItem -File $agentOutputRoot -Filter *.json | Sort-Object LastWriteTime)) {
    $agentOutputs += Read-JsonFile -Path $file.FullName
  }
}

$summary = [pscustomobject]@{
  run_id = $state.run_id
  task_identity = $state.task_identity
  objective = $state.objective
  status = $state.status
  can_finish = $state.can_finish
  counts = [pscustomobject]@{
    total_tasks = @($state.tasks).Count
    done_tasks = @($state.tasks | Where-Object { $_.status -eq 'done' }).Count
    verified_tasks = @($state.tasks | Where-Object { $_.verified -eq $true }).Count
    pending_tasks = @($state.tasks | Where-Object { $_.status -eq 'pending' }).Count
    rework_tasks = @($state.tasks | Where-Object { $_.status -eq 'needs_rework' }).Count
    total_checks = @($state.required_checks).Count
    passed_checks = @($state.required_checks | Where-Object { $_.status -eq 'pass' }).Count
    failed_checks = @($failedChecks).Count
    open_failures = @($openFailures).Count
    open_blockers = @($openBlockers).Count
    total_assignments = @($assignments).Count
    main_agent_assignments = @($assignments | Where-Object { $_.agent_role -eq 'main-agent' }).Count
    worker_agent_assignments = @($assignments | Where-Object { $_.agent_role -eq 'worker-agent' }).Count
    agent_outputs = @($agentOutputs).Count
  }
  open_tasks = @($openTasks | ForEach-Object {
      [pscustomobject]@{
        id = $_.id
        title = $_.title
        owner = $_.owner
        depends_on = @($_.depends_on)
        parallel_group = $_.parallel_group
        status = $_.status
        verified = $_.verified
      }
    })
  failed_checks = @($failedChecks | ForEach-Object {
      [pscustomobject]@{
        id = $_.id
        title = $_.title
      }
    })
  open_failures = @($openFailures | ForEach-Object {
      [pscustomobject]@{
        id = $_.id
        failure_type = $_.failure_type
        summary = $_.summary
        source_check_id = $_.source_check_id
      }
    })
  open_blockers = @($openBlockers | ForEach-Object {
      [pscustomobject]@{
        id = $_.id
        reason = $_.reason
        next_required_action = $_.next_required_action
      }
    })
  assignments = @($assignments)
  recent_agent_outputs = @($agentOutputs | Select-Object -Last 10)
  final_gate = $state.final_gate
}

if ($Detailed) {
  $summary | ConvertTo-Json -Depth 100
} else {
  [pscustomobject]@{
    Run = [pscustomobject]@{
      TaskName = $state.task_identity.task_name
      TaskSlug = $state.task_identity.task_slug
      RunId = $state.run_id
      Status = $state.status
      Objective = $state.objective
      CanFinish = $state.can_finish
    }
    Counts = $summary.counts
    OpenTasks = @($summary.open_tasks | Select-Object id, title, owner, status, verified)
    FailedChecks = @($summary.failed_checks | Select-Object id, title)
    OpenFailures = @($summary.open_failures | Select-Object id, failure_type, summary)
    OpenBlockers = @($summary.open_blockers | Select-Object id, reason)
    RecentAgentOutputs = @($summary.recent_agent_outputs | Select-Object agent_name, agent_role, task_id, summary, created_at)
    FinalGate = $summary.final_gate
  } | ConvertTo-Json -Depth 20
}
