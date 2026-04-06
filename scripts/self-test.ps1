param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$controllerRoot = Get-CodexControlRoot
$startScript = Join-Path $PSScriptRoot 'start-run.ps1'
$updateScript = Join-Path $PSScriptRoot 'update-state.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify.ps1'
$reworkScript = Join-Path $PSScriptRoot 'open-rework.ps1'
$gateScript = Join-Path $PSScriptRoot 'finish-gate.ps1'
$closeScript = Join-Path $PSScriptRoot 'close-run.ps1'
$blockScript = Join-Path $PSScriptRoot 'block-run.ps1'
$unblockScript = Join-Path $PSScriptRoot 'unblock-run.ps1'

$failProfile = Join-Path $controllerRoot 'profiles\self-test-fail.json'
$passProfile = Join-Path $controllerRoot 'profiles\self-test-pass.json'
$tasksTemplate = Join-Path $controllerRoot 'templates\self-test-tasks.json'
$defaultRunJson = & $startScript -Objective 'codex-control default profile self test' -TasksPath $tasksTemplate -Force
$defaultRun = $defaultRunJson | ConvertFrom-Json
if (-not $defaultRun.profile.path.EndsWith('profiles\default.json', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Self-test expected the default profile to be default.json, got '$($defaultRun.profile.path)'."
}

$runJson = & $startScript -Objective 'codex-control self test' -ProfilePath $failProfile -TasksPath $tasksTemplate -Force
$run = $runJson | ConvertFrom-Json
$runStatePath = $run.paths.run_state_path

& $updateScript -RunStatePath $runStatePath -Status IMPLEMENTING | Out-Null
& $updateScript -RunStatePath $runStatePath -TaskId 'controller-self-test' -TaskStatus done -TaskVerified $true | Out-Null
& $updateScript -RunStatePath $runStatePath -Status VERIFYING | Out-Null

$global:LASTEXITCODE = 0
$verifyOutput = & $verifyScript -RunStatePath $runStatePath 2>&1
$verifyExit = $LASTEXITCODE
$verifyReport = $verifyOutput | ConvertFrom-Json
if ($verifyExit -eq 0 -or -not $verifyReport.has_failure) {
  throw 'Self-test expected the first verification to fail, but it passed.'
}
if (@($verifyReport.auto_open_failures).Count -eq 0) {
  throw 'Self-test expected auto_open_failures to contain at least one entry after failed verify.'
}

& $reworkScript -RunStatePath $runStatePath -TaskId 'controller-self-test' -FailureType framework_failure -Summary 'Intentional self-test failure' -SourceCheckId intentional_failure -Details 'Expected failure path for controller self-test.' | Out-Null

$global:LASTEXITCODE = 0
$gateAfterFailureJson = & $gateScript -RunStatePath $runStatePath 2>&1
$gateAfterFailureExit = $LASTEXITCODE
$gateAfterFailure = $gateAfterFailureJson | ConvertFrom-Json
if ($gateAfterFailureExit -eq 0 -or $gateAfterFailure.can_finish) {
  throw 'Self-test expected finish-gate to reject after open failure, but it passed.'
}

& $updateScript -RunStatePath $runStatePath -ResolveAllFailures | Out-Null
& $updateScript -RunStatePath $runStatePath -TaskId 'controller-self-test' -TaskStatus done -TaskVerified $true | Out-Null
& $updateScript -RunStatePath $runStatePath -Status REVERIFYING | Out-Null

$global:LASTEXITCODE = 0
$secondVerify = & $verifyScript -RunStatePath $runStatePath -ProfilePath $passProfile -PersistProfileOverride 2>&1
$secondVerifyReport = $secondVerify | ConvertFrom-Json
if ($secondVerifyReport.has_failure) {
  throw "Self-test expected reverify to pass, but it failed: $secondVerify"
}

& $blockScript -RunStatePath $runStatePath -Reason 'self-test blocker' -Evidence 'verifying blocker handling' -NextRequiredAction 'run unblock-run' | Out-Null
$global:LASTEXITCODE = 0
$gateWithBlockerJson = & $gateScript -RunStatePath $runStatePath 2>&1
$gateWithBlockerExit = $LASTEXITCODE
$gateWithBlocker = $gateWithBlockerJson | ConvertFrom-Json
if ($gateWithBlockerExit -eq 0 -or $gateWithBlocker.can_finish) {
  throw 'Self-test expected finish-gate to reject while blocker is open, but it passed.'
}

& $unblockScript -RunStatePath $runStatePath -Reason 'self-test blocker' -NextStatus REVERIFYING | Out-Null
& $updateScript -RunStatePath $runStatePath -Status REVERIFYING | Out-Null
& $verifyScript -RunStatePath $runStatePath | Out-Null

$global:LASTEXITCODE = 0
$finalGateJson = & $gateScript -RunStatePath $runStatePath 2>&1
$finalGateExit = $LASTEXITCODE
$finalGate = $finalGateJson | ConvertFrom-Json
if ($finalGateExit -ne 0 -or -not $finalGate.can_finish) {
  throw 'Self-test expected finish-gate to pass after reverify, but it failed.'
}

$closedRunJson = & $closeScript -RunStatePath $runStatePath
$closedRun = $closedRunJson | ConvertFrom-Json
if ($closedRun.status -ne 'FINISHED') {
  throw "Self-test expected final status FINISHED, got '$($closedRun.status)'."
}
if ($null -eq $closedRun.closeout) {
  throw 'Self-test expected close-run to record closeout metadata, but it was missing.'
}

$report = [pscustomobject]@{
  ok = $true
  run_id = $closedRun.run_id
  final_status = $closedRun.status
  failure_path_exercised = $true
  reverify_path_exercised = $true
  finish_gate_enforced = $true
  blocker_path_exercised = $true
  default_profile = $defaultRun.profile.path
}

$report | ConvertTo-Json -Depth 100
