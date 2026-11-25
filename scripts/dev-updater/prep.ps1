# Prepare the next OpenBot Dev worktree while the current app keeps running.
# Default mode is dry-run. -Mode run fetches upstream, merges it in a new
# worktree, installs, builds, and typechecks. It does not stop or start the app.
# Requires Windows PowerShell 5.1.

param(
    [ValidateSet('dry-run', 'run', 'discover')]
    [string]$Mode = 'dry-run',
    [string]$OldWorktree = '',
    [string]$InstanceId = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$paths = Get-OpenBotUpdaterPaths
$env:GIT_TERMINAL_PROMPT = '0'

function Resolve-OldWorktree {
    if ($OldWorktree) { return (Get-OpenBotFullPath $OldWorktree) }
    $current = Read-OpenBotJson $paths.Current
    if ($current -and $current.worktree -and (Test-Path -LiteralPath $current.worktree)) {
        return (Get-OpenBotFullPath $current.worktree)
    }
    return (Get-OpenBotFullPath $paths.LiveWorktree)
}

function Get-LiveRecords([string]$Worktree) {
    $wanted = Get-OpenBotFullPath $Worktree
    $instance = $null
    $stack = $null
    if (Test-Path -LiteralPath $paths.Registry) {
        Get-ChildItem -LiteralPath $paths.Registry -Filter '*.json' -File | ForEach-Object {
            $record = Read-OpenBotJson $_.FullName
            $names = @($record.PSObject.Properties.Name)
            if ($names -notcontains 'projectRoot') { return }
            if ((Get-OpenBotFullPath $record.projectRoot) -ne $wanted) { return }
            $alive = $false
            if ($names -contains 'pid' -and $record.pid) {
                $alive = [bool](Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue)
            }
            $isApp = ($names -notcontains 'service') -or ($record.service -eq 'app')
            if (($names -contains 'instanceId') -and $record.instanceId -and $isApp -and ($alive -or -not $instance)) {
                $instance = $record
            }
            if (($names -contains 'ports') -and $record.ports -and (-not $stack -or $alive)) { $stack = $record }
        }
        $stackDir = [IO.Path]::Combine($paths.Registry, 'stacks')
        if (Test-Path -LiteralPath $stackDir) {
            Get-ChildItem -LiteralPath $stackDir -Filter '*.json' -File | ForEach-Object {
                $record = Read-OpenBotJson $_.FullName
                $names = @($record.PSObject.Properties.Name)
                if ($names -notcontains 'projectRoot' -or $names -notcontains 'ports') { return }
                if ((Get-OpenBotFullPath $record.projectRoot) -ne $wanted) { return }
                $alive = $false
                if (($names -contains 'supervisorPid') -and $record.supervisorPid) {
                    $alive = [bool](Get-Process -Id ([int]$record.supervisorPid) -ErrorAction SilentlyContinue)
                }
                if ($alive -or -not $stack) { $stack = $record }
            }
        }
    }
    return @{ instance = $instance; stack = $stack }
}

function Get-PortMap($Stack) {
    $map = @{ api = 3100; signal = 3101; health = 3102; renderer = 5173 }
    if (-not $Stack -or -not $Stack.ports) { return $map }
    foreach ($port in @($Stack.ports)) {
        if ($port.name -eq 'api') { $map.api = [int]$port.port }
        elseif ($port.name -eq 'signal') { $map.signal = [int]$port.port }
        elseif ($port.name -eq 'signal-health') { $map.health = [int]$port.port }
        elseif ($port.name -eq 'app-renderer') { $map.renderer = [int]$port.port }
    }
    return $map
}

function Assert-PinnedBun {
    if (-not (Test-Path -LiteralPath $paths.Bun)) { throw "Pinned Bun is missing at $($paths.Bun)." }
    $bunDir = Split-Path -Parent $paths.Bun
    $previous = $env:PATH
    $env:PATH = "$bunDir;$previous"
    try {
        $version = (& $paths.Bun --version).Trim()
    }
    finally {
        $env:PATH = $previous
    }
    if ($version -ne '1.4.2') { throw "Pinned Bun must be 1.4.2, got $version." }
}

function Invoke-BunIn([string]$Worktree, [string[]]$Arguments) {
    $bunDir = Split-Path -Parent $paths.Bun
    $previous = $env:PATH
    $env:PATH = "$bunDir;$previous"
    Write-OpenBotLog $paths.PrepLog ("bun " + ($Arguments -join ' ') + " in $Worktree")
    Push-Location $Worktree
    try {
        & $paths.Bun @Arguments *>> $paths.PrepLog
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $env:PATH = $previous
    }
    if ($code -ne 0) { throw "bun $($Arguments -join ' ') failed with exit $code. See $($paths.PrepLog)." }
}

function Copy-UpdaterIntoWorktree([string]$Worktree) {
    $scriptDest = [IO.Path]::Combine($Worktree, 'scripts', 'dev-updater')
    $skillDest = [IO.Path]::Combine($Worktree, '.agents', 'skills', 'update-openbot-dev')
    Ensure-OpenBotDirectory $scriptDest
    Ensure-OpenBotDirectory $skillDest
    Copy-Item -LiteralPath ([IO.Path]::Combine($PSScriptRoot, 'common.ps1')) -Destination $scriptDest -Force
    Copy-Item -LiteralPath ([IO.Path]::Combine($PSScriptRoot, 'prep.ps1')) -Destination $scriptDest -Force
    Copy-Item -LiteralPath ([IO.Path]::Combine($PSScriptRoot, 'swap.ps1')) -Destination $scriptDest -Force
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidates = @(
        [IO.Path]::Combine($PSScriptRoot, 'skill', 'SKILL.md'),
        [IO.Path]::Combine($repoRoot, '.agents', 'skills', 'update-openbot-dev', 'SKILL.md')
    )
    $skillSource = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($skillSource -and (Test-Path -LiteralPath $skillSource)) {
        Copy-Item -LiteralPath $skillSource -Destination ([IO.Path]::Combine($skillDest, 'SKILL.md')) -Force
    }
    Push-Location $Worktree
    try {
        & git add -- scripts/dev-updater .agents/skills/update-openbot-dev
        $staged = & git diff --cached --name-only
        if (-not $staged) { return }
        & git commit -m "Add the OpenBot dev updater"
        if ($LASTEXITCODE -ne 0) { throw 'Could not commit the updater onto the new worktree.' }
    }
    finally {
        Pop-Location
    }
}

$old = Resolve-OldWorktree
$records = Get-LiveRecords $old
$resolvedId = $InstanceId
if (-not $resolvedId -and $records.instance) { $resolvedId = [string]$records.instance.instanceId }
$ports = Get-PortMap $records.stack

if ($Mode -eq 'discover') {
    Write-Output ("worktree=" + $old)
    Write-Output ("instanceId=" + $resolvedId)
    Write-Output ("api=" + $ports.api)
    Write-Output ("signal=" + $ports.signal)
    Write-Output ("health=" + $ports.health)
    Write-Output ("renderer=" + $ports.renderer)
    exit 0
}

Assert-PinnedBun
if (-not (Test-Path -LiteralPath $old)) { throw "The current worktree does not exist: $old" }

if ($Mode -eq 'dry-run') {
    Write-OpenBotJson $paths.Result @{
        status     = 'prep-dry-run'
        worktree   = $old
        instanceId = $resolvedId
        bun        = $paths.Bun
        ports      = $ports
        finishedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-Output "Dry run only. Live app was not changed. Would prepare a new worktree from $old."
    exit 0
}

if (-not $resolvedId) { throw 'No dev instance id was found. Pass -InstanceId. The live app was not changed.' }
if ($resolvedId -notmatch '^(?:\d{4,5}|wt-[a-f0-9]{64})$') { throw "Instance id is not a dev profile id: $resolvedId" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$branch = "deploy/openbot-update-$stamp"
$new = [IO.Path]::Combine($paths.Worktrees, "update-$stamp")
if (Test-Path -LiteralPath $new) { throw "Refusing to reuse $new." }

Write-OpenBotLog $paths.PrepLog "Preparing $branch from $old"
Push-Location $old
try {
    & git fetch upstream
    if ($LASTEXITCODE -ne 0) { throw 'git fetch upstream failed. The live worktree was not changed.' }
    $head = (& git rev-parse HEAD).Trim()
    & git worktree add -b $branch $new $head
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the new worktree. The live worktree was not changed.' }
}
finally {
    Pop-Location
}

$merged = $false
try {
    Copy-UpdaterIntoWorktree $new
    Push-Location $new
    try {
        & git merge --no-edit upstream/main
        if ($LASTEXITCODE -ne 0) {
            & git merge --abort
            throw 'Merging upstream/main failed. The merge was aborted in the new worktree. The live app was not changed.'
        }
        $wrangler = [IO.Path]::Combine((Get-Location).Path, 'apps', 'auth-api', '.wrangler')
        $createdWrangler = $false
        if (-not (Test-Path -LiteralPath $wrangler)) {
            Ensure-OpenBotDirectory $wrangler
            $createdWrangler = $true
        }
        & git check-ignore -q -- apps/auth-api/.wrangler
        $ignored = $LASTEXITCODE
        if ($createdWrangler) { Remove-Item -LiteralPath $wrangler -Force }
        if ($ignored -ne 0) { throw 'apps/auth-api/.wrangler is not gitignored. The live app was not changed.' }
    }
    finally {
        Pop-Location
    }
    $merged = $true
    Invoke-BunIn $new @('install', '--frozen-lockfile')
    Invoke-BunIn $new @('run', 'build')
    Invoke-BunIn $new @('run', 'typecheck')
    $commit = (git -C $new rev-parse HEAD).Trim()
    Write-OpenBotJson $paths.Plan @{
        oldWorktree = $old
        newWorktree = $new
        branch      = $branch
        commit      = $commit
        instanceId  = $resolvedId
        bun         = $paths.Bun
        ports       = $ports
        createdAt   = [DateTimeOffset]::Now.ToString('o')
    }
    Write-OpenBotJson ([IO.Path]::Combine($paths.Root, 'prep-result.json')) @{
        status   = 'prepared'
        plan     = $paths.Plan
        worktree = $new
        commit   = $commit
    }
    Write-Output "Prepared $new ($commit). Plan: $($paths.Plan)"
}
catch {
    Write-OpenBotLog $paths.PrepLog $_.Exception.Message
    if (-not $merged) {
        Write-OpenBotJson ([IO.Path]::Combine($paths.Root, 'prep-result.json')) @{
            status  = 'failed'
            detail  = $_.Exception.Message
            worktree = $new
        }
    }
    else {
        Write-OpenBotJson ([IO.Path]::Combine($paths.Root, 'prep-result.json')) @{
            status   = 'failed'
            detail   = $_.Exception.Message
            worktree = $new
        }
        if (Test-Path -LiteralPath $paths.Plan) { Remove-Item -LiteralPath $paths.Plan -Force }
    }
    throw
}
