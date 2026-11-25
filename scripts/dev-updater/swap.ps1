# Swap a prepared OpenBot Dev worktree from outside the app.
# Default mode is dry-run, so launching this file cannot stop the live app.
# The real swap runs only as -Mode swap, started by a one-time scheduled task.
# Requires Windows PowerShell 5.1.

param(
    [ValidateSet('dry-run', 'swap', 'register', 'self-test')]
    [string]$Mode = 'dry-run'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$paths = Get-OpenBotUpdaterPaths

function Test-TcpOpen([string]$HostName, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect($HostName, $Port, $null, $null)
        $opened = $wait.AsyncWaitHandle.WaitOne(1000, $false)
        if (-not $opened) { return $false }
        $client.EndConnect($wait) | Out-Null
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Test-HttpStatus([string]$Url) {
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Timeout = 4000
        $request.Method = 'GET'
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $response.Close()
        return $code
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

function Wait-OpenBotHealthy($Plan, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = 'not checked'
    do {
        $api = Test-HttpStatus ("http://127.0.0.1:{0}/" -f $Plan.ports.api)
        $signal = Test-TcpOpen '127.0.0.1' ([int]$Plan.ports.signal)
        $health = Test-HttpStatus ("http://127.0.0.1:{0}/health/live" -f $Plan.ports.health)
        $renderer = Test-HttpStatus ("http://[::1]:{0}/" -f $Plan.ports.renderer)
        $last = "api=$api signal=$signal health=$health renderer=$renderer"
        if ($api -eq 200 -and $signal -and $health -eq 200 -and $renderer -eq 200) {
            return @{ ok = $true; detail = $last }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return @{ ok = $false; detail = $last }
}

function Wait-OpenBotPortsFree($Plan, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $busy = @()
        if (Test-TcpOpen '127.0.0.1' ([int]$Plan.ports.api)) { $busy += 'api' }
        if (Test-TcpOpen '127.0.0.1' ([int]$Plan.ports.signal)) { $busy += 'signal' }
        if (Test-TcpOpen '127.0.0.1' ([int]$Plan.ports.health)) { $busy += 'health' }
        if (Test-TcpOpen '::1' ([int]$Plan.ports.renderer)) { $busy += 'renderer' }
        if ($busy.Count -eq 0) { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw ("Ports still in use after dev:stop: " + ($busy -join ', '))
}

function Invoke-DevStop([string]$Worktree) {
    $bunDir = Split-Path -Parent $paths.Bun
    $previous = $env:PATH
    $env:PATH = "$bunDir;$previous"
    Write-OpenBotLog $paths.SwapLog "dev:stop in $Worktree"
    Push-Location $Worktree
    try {
        & $paths.Bun run dev:stop *>> $paths.SwapLog
        if ($LASTEXITCODE -ne 0) { throw "dev:stop failed in $Worktree with exit $LASTEXITCODE." }
    }
    finally {
        Pop-Location
        $env:PATH = $previous
    }
}

function Start-DevBuild([string]$Worktree, [string]$InstanceId) {
    $bunDir = Split-Path -Parent $paths.Bun
    $stdout = [IO.Path]::Combine($paths.Root, 'dev-stdout.log')
    $stderr = [IO.Path]::Combine($paths.Root, 'dev-stderr.log')
    $previousPath = $env:PATH
    $previousId = $env:OPENBOT_DEV_INSTANCE_ID
    $env:PATH = "$bunDir;$previousPath"
    $env:OPENBOT_DEV_INSTANCE_ID = $InstanceId
    try {
        $proc = Start-Process -FilePath $paths.Bun -ArgumentList @('run', 'dev') -WorkingDirectory $Worktree -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    }
    finally {
        $env:PATH = $previousPath
        if ($null -eq $previousId) { Remove-Item Env:OPENBOT_DEV_INSTANCE_ID -ErrorAction SilentlyContinue }
        else { $env:OPENBOT_DEV_INSTANCE_ID = $previousId }
    }
    Write-OpenBotJson $paths.StartedPids @{ pid = $proc.Id; worktree = $Worktree }
    Write-OpenBotLog $paths.SwapLog "Started PID $($proc.Id) in $Worktree"
    return $proc.Id
}

function Stop-StartedDev([string]$Worktree) {
    try { Invoke-DevStop $Worktree } catch { Write-OpenBotLog $paths.SwapLog $_.Exception.Message }
    $started = Read-OpenBotJson $paths.StartedPids
    if (-not $started -or -not $started.pid) { return }
    $procId = [int]$started.pid
    if ((Get-OpenBotFullPath $started.worktree) -ne (Get-OpenBotFullPath $Worktree)) { return }
    if (Test-OpenBotOwnedProcess $procId $Worktree) {
        Stop-Process -Id $procId -Force
        Write-OpenBotLog $paths.SwapLog "Stopped owned PID $procId"
    }
}

function Register-SwapTask {
    $existing = Get-ScheduledTask -TaskName $paths.TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.State -eq 'Running') { throw 'The OpenBot swap task is already running.' }
        Ensure-OpenBotDirectory $paths.Root
        Export-ScheduledTask -TaskName $paths.TaskName | Out-File -FilePath ([IO.Path]::Combine($paths.Root, 'task-backup.xml')) -Encoding unicode
        Unregister-ScheduledTask -TaskName $paths.TaskName -Confirm:$false
    }
    $argument = Get-OpenBotSwapTaskArgument ([IO.Path]::Combine($PSScriptRoot, 'swap.ps1'))
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argument
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $paths.TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
}

function Invoke-Swap {
    $plan = Read-OpenBotJson $paths.Plan
    if (-not $plan) { throw "No plan at $($paths.Plan). Run prep -Mode run first." }
    foreach ($name in @('oldWorktree', 'newWorktree', 'instanceId', 'bun')) {
        if (-not $plan.$name) { throw "Plan is missing $name." }
    }
    if (-not (Test-Path -LiteralPath $plan.bun)) { throw "Pinned Bun is missing at $($plan.bun)." }
    if (-not (Test-Path -LiteralPath $plan.oldWorktree)) { throw "Old worktree is missing: $($plan.oldWorktree)" }
    if (-not (Test-Path -LiteralPath $plan.newWorktree)) { throw "New worktree is missing: $($plan.newWorktree)" }
    $script:paths = Get-OpenBotUpdaterPaths
    $script:paths.Bun = [string]$plan.bun

    $profile = [IO.Path]::Combine($env:APPDATA, ("OpenBot Dev {0}" -f $plan.instanceId))
    if (-not (Test-Path -LiteralPath $profile)) { throw "Dev profile is missing: $profile. The app was not stopped." }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = [IO.Path]::Combine($paths.Backups, $stamp)
    $authSource = [IO.Path]::Combine($plan.oldWorktree, 'apps', 'auth-api', '.wrangler')
    if (-not (Test-Path -LiteralPath $authSource) -and (Test-Path -LiteralPath $paths.AuthState)) {
        $authSource = $paths.AuthState
    }
    Backup-OpenBotDirectory $profile ([IO.Path]::Combine($backup, 'profile'))
    if (Test-Path -LiteralPath $authSource) {
        Backup-OpenBotDirectory $authSource ([IO.Path]::Combine($backup, 'auth-api'))
    }
    Write-OpenBotLog $paths.SwapLog "Backed up to $backup"

    Invoke-DevStop $plan.oldWorktree
    Wait-OpenBotPortsFree $plan 90
    Install-OpenBotAuthJunction $plan.oldWorktree $paths.AuthState
    Install-OpenBotAuthJunction $plan.newWorktree $paths.AuthState

    $started = Start-DevBuild $plan.newWorktree $plan.instanceId
    $health = Wait-OpenBotHealthy $plan 300
    if ($health.ok) {
        $commit = (git -C $plan.newWorktree rev-parse HEAD).Trim()
        Write-OpenBotJson $paths.Current @{
            worktree   = [string]$plan.newWorktree
            commit     = $commit
            instanceId = [string]$plan.instanceId
            updatedAt  = [DateTimeOffset]::Now.ToString('o')
        }
        Write-OpenBotJson $paths.Result @{
            status      = 'success'
            oldWorktree = [string]$plan.oldWorktree
            newWorktree = [string]$plan.newWorktree
            commit      = $commit
            backup      = $backup
            health      = $health.detail
            startedPid  = $started
            finishedAt  = [DateTimeOffset]::Now.ToString('o')
        }
        Write-OpenBotLog $paths.SwapLog "Swap succeeded. $commit"
        return
    }

    Write-OpenBotLog $paths.SwapLog ("New build failed health. " + $health.detail)
    Stop-StartedDev $plan.newWorktree
    Wait-OpenBotPortsFree $plan 90
    $restored = Start-DevBuild $plan.oldWorktree $plan.instanceId
    $oldHealth = Wait-OpenBotHealthy $plan 300
    Write-OpenBotJson $paths.Result @{
        status      = $(if ($oldHealth.ok) { 'rolled-back' } else { 'failed' })
        oldWorktree = [string]$plan.oldWorktree
        newWorktree = [string]$plan.newWorktree
        backup      = $backup
        health      = $health.detail
        rollback    = $oldHealth.detail
        startedPid  = $restored
        finishedAt  = [DateTimeOffset]::Now.ToString('o')
    }
    if (-not $oldHealth.ok) { throw "Rollback did not become healthy. $($oldHealth.detail)" }
}

function Invoke-SelfTest {
    $root = [IO.Path]::Combine($env:LOCALAPPDATA, 'OpenBot', 'updater-selftest', [guid]::NewGuid().ToString('n'))
    $liveAuth = $paths.AuthState
    $liveLink = [IO.Path]::Combine($paths.LiveWorktree, 'apps', 'auth-api', '.wrangler')
    $beforeAuth = Test-Path -LiteralPath $liveAuth
    $beforeLink = $false
    $beforeTarget = ''
    $old = ''
    $new = ''
    $other = ''
    if (Test-Path -LiteralPath $liveLink) {
        $beforeLink = $true
        $item = Get-Item -LiteralPath $liveLink -Force
        $beforeTarget = [string]$item.Attributes
    }
    try {
        $old = [IO.Path]::Combine($root, 'old')
        $new = [IO.Path]::Combine($root, 'new')
        $permanent = [IO.Path]::Combine($root, 'permanent', '.wrangler')
        $source = [IO.Path]::Combine($old, 'apps', 'auth-api', '.wrangler')
        Ensure-OpenBotDirectory $source
        [IO.File]::WriteAllText([IO.Path]::Combine($source, 'marker.txt'), 'account')
        if ((Install-OpenBotAuthJunction $old $permanent) -eq 'already') { throw 'Expected a new junction.' }
        $marker = [IO.File]::ReadAllText([IO.Path]::Combine($permanent, 'marker.txt'))
        if ($marker -ne 'account') { throw 'Account marker was not moved to the permanent folder.' }
        Install-OpenBotAuthJunction $new $permanent | Out-Null
        [IO.File]::WriteAllText([IO.Path]::Combine($permanent, 'marker.txt'), 'shared')
        $fromNew = [IO.File]::ReadAllText([IO.Path]::Combine($new, 'apps', 'auth-api', '.wrangler', 'marker.txt'))
        if ($fromNew -ne 'shared') { throw 'The new worktree does not see the shared account state.' }
        Remove-OpenBotJunction ([IO.Path]::Combine($new, 'apps', 'auth-api', '.wrangler'))
        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($permanent, 'marker.txt')))) {
            throw 'Removing a junction deleted the permanent account state.'
        }
        $occupied = [IO.Path]::Combine($root, 'occupied')
        $other = [IO.Path]::Combine($root, 'other-tree')
        Ensure-OpenBotDirectory ([IO.Path]::Combine($occupied, 'keep'))
        [IO.File]::WriteAllText([IO.Path]::Combine($occupied, 'keep', 'a.txt'), 'keep')
        Ensure-OpenBotDirectory ([IO.Path]::Combine($other, 'apps', 'auth-api', '.wrangler'))
        [IO.File]::WriteAllText([IO.Path]::Combine($other, 'apps', 'auth-api', '.wrangler', 'b.txt'), 'other')
        $refused = $false
        try { Install-OpenBotAuthJunction $other $occupied | Out-Null } catch { $refused = $true }
        if (-not $refused) { throw 'Two populated account folders were not refused.' }
        $profile = [IO.Path]::Combine($root, 'profile')
        Ensure-OpenBotDirectory $profile
        [IO.File]::WriteAllText([IO.Path]::Combine($profile, 'note.txt'), 'profile')
        Backup-OpenBotDirectory $profile ([IO.Path]::Combine($root, 'backup'))
        if ([IO.File]::ReadAllText([IO.Path]::Combine($root, 'backup', 'note.txt')) -ne 'profile') {
            throw 'Profile backup did not keep the file.'
        }
        $argument = Get-OpenBotSwapTaskArgument 'C:\OpenBot\updater\swap.ps1'
        if ($argument -notmatch '-WindowStyle Hidden' -or $argument -notmatch '-Mode swap') {
            throw 'The scheduled task would not start a hidden swap.'
        }
        $owned = Test-OpenBotOwnedProcess $PID $old
        if ($owned) { throw 'The self-test process was treated as an owned dev process.' }
        Enter-OpenBotLock ([IO.Path]::Combine($root, 'swap.lock'))
        $locked = $false
        try { Enter-OpenBotLock ([IO.Path]::Combine($root, 'swap.lock')) } catch { $locked = $true }
        if (-not $locked) { throw 'A live lock was not honored.' }
        Exit-OpenBotLock ([IO.Path]::Combine($root, 'swap.lock'))
    }
    finally {
        $links = @()
        if ($old) { $links += [IO.Path]::Combine($old, 'apps', 'auth-api', '.wrangler') }
        if ($new) { $links += [IO.Path]::Combine($new, 'apps', 'auth-api', '.wrangler') }
        if ($other) { $links += [IO.Path]::Combine($other, 'apps', 'auth-api', '.wrangler') }
        foreach ($link in $links) {
            if (Test-Path -LiteralPath $link) {
                $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
                if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    Remove-OpenBotJunction $link
                }
            }
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    $afterAuth = Test-Path -LiteralPath $liveAuth
    if ($beforeAuth -ne $afterAuth) { throw 'Self-test changed the permanent account folder.' }
    if ($beforeLink) {
        $afterItem = Get-Item -LiteralPath $liveLink -Force
        if ([string]$afterItem.Attributes -ne $beforeTarget) { throw 'Self-test changed the live .wrangler link.' }
    }
    Write-OpenBotJson $paths.Result @{
        status     = 'self-test'
        detail     = 'Junction, backup, lock, and task argument checks passed. The live app was not stopped.'
        finishedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-Output 'Self-test passed. The live app was not changed.'
}

if ($Mode -eq 'self-test') {
    Invoke-SelfTest
    exit 0
}

if ($Mode -eq 'register') {
    if (-not (Test-Path -LiteralPath $paths.Plan)) { throw "No plan at $($paths.Plan). Run prep -Mode run first." }
    Register-SwapTask
    Write-Output "Scheduled $($paths.TaskName). OpenBot will restart in a few seconds."
    exit 0
}

if ($Mode -eq 'dry-run') {
    $plan = Read-OpenBotJson $paths.Plan
    Write-OpenBotJson $paths.Result @{
        status     = 'dry-run'
        hasPlan    = [bool]$plan
        detail     = 'Dry run only. The live app was not stopped or started.'
        finishedAt = [DateTimeOffset]::Now.ToString('o')
    }
    if ($plan) { Write-Output "Dry run. Would swap $($plan.oldWorktree) to $($plan.newWorktree)." }
    else { Write-Output 'Dry run. No plan is waiting. The live app was not changed.' }
    exit 0
}

Enter-OpenBotLock $paths.Lock
try {
    Invoke-Swap
    Unregister-ScheduledTask -TaskName $paths.TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-OpenBotLog $paths.SwapLog $_.Exception.Message
    $existing = Read-OpenBotJson $paths.Result
    if (-not $existing -or $existing.status -eq 'dry-run' -or $existing.status -eq 'self-test') {
        Write-OpenBotJson $paths.Result @{
            status     = 'failed'
            detail     = $_.Exception.Message
            finishedAt = [DateTimeOffset]::Now.ToString('o')
        }
    }
    throw
}
finally {
    Exit-OpenBotLock $paths.Lock
}
