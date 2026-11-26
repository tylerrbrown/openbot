# Shared paths and account-state junctions for the OpenBot dev updater.
# Windows PowerShell 5.1. Dot-source this file; it does not change the live app.

Set-StrictMode -Version 2.0

function Get-OpenBotUpdaterPaths {
    $local = $env:LOCALAPPDATA
    if (-not $local) { throw 'LOCALAPPDATA is not set.' }
    $root = [IO.Path]::Combine($local, 'OpenBot', 'updater')
    [pscustomobject]@{
        Root         = $root
        Plan         = [IO.Path]::Combine($root, 'plan.json')
        Current      = [IO.Path]::Combine($root, 'current.json')
        Result       = [IO.Path]::Combine($root, 'result.json')
        SwapLog      = [IO.Path]::Combine($root, 'swap.log')
        PrepLog      = [IO.Path]::Combine($root, 'prep.log')
        Lock         = [IO.Path]::Combine($root, 'swap.lock')
        StartedPids  = [IO.Path]::Combine($root, 'started-pids.json')
        AuthState    = [IO.Path]::Combine($local, 'OpenBot', 'dev-state', 'auth-api', '.wrangler')
        Backups      = [IO.Path]::Combine($local, 'OpenBot', 'Dev Backups')
        Registry     = [IO.Path]::Combine($local, 'OpenBot', 'openbot-dev-instances')
        Bun          = 'C:\Users\tyler.TYWARE\src\openbot\.local-tools\node_modules\bun\bin\bun.exe'
        LiveWorktree = 'C:\Repos\tylerrbrown\openbot\worktrees\upstream-078-integration'
        Worktrees    = 'C:\Repos\tylerrbrown\openbot\worktrees'
        TaskName     = 'OpenBot Dev Updater Swap'
    }
}

function Ensure-OpenBotDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Write-OpenBotJson([string]$Path, $Object) {
    Ensure-OpenBotDirectory (Split-Path -Parent $Path)
    $tmp = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($tmp, $json, $utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-OpenBotJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path)
    if (-not $raw.Trim()) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-OpenBotLog([string]$Path, [string]$Message) {
    Ensure-OpenBotDirectory (Split-Path -Parent $Path)
    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-OpenBotFullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-OpenBotJunctionTo([string]$Link, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Link)) { return $false }
    $item = Get-Item -LiteralPath $Link -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $resolved = $item.Target
    if ($resolved -is [System.Array]) { $resolved = $resolved[0] }
    if (-not $resolved) { return $false }
    return (Get-OpenBotFullPath $resolved) -eq (Get-OpenBotFullPath $Target)
}

function Remove-OpenBotJunction([string]$Link) {
    # rmdir removes the junction only. Remove-Item would delete the target.
    $quoted = '"' + $Link + '"'
    & cmd.exe /c "rmdir $quoted"
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the junction at $Link." }
}

function Move-OpenBotDirectory([string]$Source, [string]$Destination) {
    $sourceRoot = [IO.Path]::GetPathRoot((Get-OpenBotFullPath $Source))
    $destRoot = [IO.Path]::GetPathRoot((Get-OpenBotFullPath $Destination))
    if ($sourceRoot -eq $destRoot) {
        Move-Item -LiteralPath $Source -Destination $Destination
        return
    }
    Ensure-OpenBotDirectory $Destination
    & robocopy.exe $Source $Destination /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Could not copy $Source to $Destination (robocopy $LASTEXITCODE)." }
    Remove-Item -LiteralPath $Source -Recurse -Force
}

function Install-OpenBotAuthJunction([string]$Worktree, [string]$Permanent) {
    $link = [IO.Path]::Combine($Worktree, 'apps', 'auth-api', '.wrangler')
    Ensure-OpenBotDirectory (Split-Path -Parent $link)
    if (Test-OpenBotJunctionTo $link $Permanent) { return 'already' }

    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($isLink) {
            Remove-OpenBotJunction $link
        }
        elseif (-not (Test-Path -LiteralPath $Permanent)) {
            Ensure-OpenBotDirectory (Split-Path -Parent $Permanent)
            Move-OpenBotDirectory $link $Permanent
        }
        else {
            $sourceFiles = @(Get-ChildItem -LiteralPath $link -Force -Recurse -File -ErrorAction SilentlyContinue)
            if ($sourceFiles.Count -gt 0) {
                throw "Both $link and $Permanent already contain account state. Refusing to overwrite either."
            }
            Remove-Item -LiteralPath $link -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $Permanent)) {
        Ensure-OpenBotDirectory $Permanent
    }
    New-Item -ItemType Junction -Path $link -Target $Permanent | Out-Null
    if (-not (Test-OpenBotJunctionTo $link $Permanent)) {
        throw "The account-state junction at $link does not point at $Permanent."
    }
    return 'linked'
}

function Get-OpenBotInventory([string]$Path, [switch]$AccountHashes) {
    $root = Get-OpenBotFullPath $Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Directory missing: $root." }
    Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction Stop | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length + 1)
        if (-not $AccountHashes) { "$relative`t$($_.Length)" }
        # SHM is a transient index, not account data. It still belongs in the full backup.
        elseif ($_.Name -match '\.sqlite(?:-wal)?$|^\.openbot-migrate-local-stamp$') {
            "$relative`t$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    }
}

function Backup-OpenBotDirectory([string]$Source, [string]$Destination) {
    $before = @(Get-OpenBotInventory $Source)
    if (Test-Path -LiteralPath $Destination) { throw "Backup destination already exists: $Destination." }
    Ensure-OpenBotDirectory $Destination
    & robocopy.exe $Source $Destination /E /COPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Backup of $Source failed (robocopy $LASTEXITCODE)." }
    $after = @(Get-OpenBotInventory $Destination)
    if ($before.Count -ne $after.Count -or ($before -join "`n") -cne ($after -join "`n")) {
        throw "Backup file count or size does not match: $Destination."
    }
}

function Enter-OpenBotLock([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $owner = 0
        $text = [IO.File]::ReadAllText($Path).Trim()
        [void][int]::TryParse($text, [ref]$owner)
        if ($owner -gt 0 -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
            throw "The OpenBot updater lock is held by PID $owner."
        }
    }
    Ensure-OpenBotDirectory (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path, "$PID")
}

function Exit-OpenBotLock([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $text = [IO.File]::ReadAllText($Path).Trim()
        if ($text -eq "$PID") { Remove-Item -LiteralPath $Path -Force }
    }
}

function Test-OpenBotOwnedProcess([int]$ProcessId, [string]$Worktree) {
    if ($ProcessId -le 0) { return $false }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $proc -or -not $proc.CommandLine) { return $false }
    $needle = Get-OpenBotFullPath $Worktree
    return $proc.CommandLine.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-OpenBotSwapTaskArgument([string]$SwapScript) {
    return "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SwapScript`" -Mode swap"
}

function Restore-OpenBotDevReadyTimeout([string]$Worktree) {
    $path = [IO.Path]::Combine($Worktree, 'scripts', 'dev-services.ts')
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $source = $utf8.GetString([IO.File]::ReadAllBytes($path))
    # shortcut: match the two known wait loops; update these anchors if upstream moves the deadlines.
    $deadline = '\([^\r\n]*(\r?\n)(?:[^\r\n]*\r?\n){2}  const deadline = Date\.now\(\) \+ (30_000|developmentReadyTimeoutMs\(\));\r?$'
    $api = [regex]::Match($source, '(?m)^async function waitForDevelopmentApi' + $deadline)
    $remote = [regex]::Match($source, '(?m)^async function waitForDevelopmentRemote' + $deadline)
    $helper = @'
function developmentReadyTimeoutMs(): number {
  const timeout = Number(process.env.OPENBOT_DEV_READY_TIMEOUT_MS);
  return Number.isSafeInteger(timeout) && timeout > 0 ? timeout : 180_000;
}
'@
    $newline = $api.Groups[1].Value
    $helper = $helper.Replace("`r`n", "`n").Replace("`n", $newline)
    $call = 'developmentReadyTimeoutMs()'
    if ($api.Groups[2].Value -ceq $call -and $remote.Groups[2].Value -ceq $call -and
        $source.Contains($helper)) { return $false }
    if ($api.Groups[2].Value -cne '30_000' -or $remote.Groups[2].Value -cne '30_000' -or
        $source.Contains('OPENBOT_DEV_READY_TIMEOUT_MS')) {
        throw "Could not restore the dev readiness timeout in $path; the wait loops have changed."
    }

    foreach ($match in @(@($api, $remote) | Sort-Object Index -Descending)) {
        $start = $match.Groups[2].Index
        $source = $source.Remove($start, $match.Groups[2].Length).Insert($start, $call)
    }
    $source = $source.Insert($api.Index, $helper + $newline + $newline)
    $temp = "$path.$([guid]::NewGuid()).tmp"
    try {
        [IO.File]::WriteAllBytes($temp, $utf8.GetBytes($source))
        [IO.File]::Replace($temp, $path, [NullString]::Value)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
    return $true
}
