param(
    [ValidateSet("Interactive", "Start")]
    [string] $Operation = "Interactive"
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
$serverVersion = "edge"
$versionFile = Join-Path $PSScriptRoot "VERSION"
if (Test-Path -LiteralPath $versionFile) {
    $serverVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    if ($serverVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "The server bundle VERSION file is invalid. Download the package again."
    }
}

function New-UrlSafeSecret([int] $ByteCount) {
    $bytes = New-Object byte[] $ByteCount
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
}

function Assert-SafeValue([string] $Value, [string] $Label) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\r\n$"''{}]') {
        throw "$Label contains unsupported characters."
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker Desktop is required. Install it, start it, then run this launcher again."
}
$dockerReady = $false
$attemptLimit = if ($Operation -eq "Start") { 60 } else { 1 }
for ($attempt = 0; $attempt -lt $attemptLimit; $attempt++) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { $dockerReady = $true; break }
    if ($attempt + 1 -lt $attemptLimit) { Start-Sleep -Seconds 2 }
}
if (-not $dockerReady) { throw "Docker Desktop is installed but is not running." }

$environmentFile = Join-Path $PSScriptRoot ".env"
$newInstall = -not (Test-Path -LiteralPath $environmentFile)
if ($newInstall -and $Operation -eq "Start") {
    throw "Automatic startup needs first-time setup. Run start-windows.cmd interactively once."
}
if ($newInstall) {
    Write-Host "ClearPocket Server first-time setup"
    Write-Host "The iPhone app requires HTTPS for remote servers. This preview starts a local server; do not expose port 8080 to the Internet."
    $hostName = Read-Host "This PC's protected-LAN hostname or IP address"
    Assert-SafeValue $hostName "Hostname"

    $defaultRoot = Join-Path $env:LOCALAPPDATA "ClearPocket Server\Data"
    $storageRoot = Read-Host "Data folder [$defaultRoot]"
    if ([string]::IsNullOrWhiteSpace($storageRoot)) { $storageRoot = $defaultRoot }
    $storageRoot = [IO.Path]::GetFullPath($storageRoot)
    Assert-SafeValue $storageRoot "Data folder"
    $database = Join-Path $storageRoot "database"
    $attachments = Join-Path $storageRoot "attachments"
    $operations = Join-Path $storageRoot "operations"
    New-Item -ItemType Directory -Force -Path $database, $attachments, $operations | Out-Null
    $databaseDocker = $database.Replace('\', '/')
    $attachmentsDocker = $attachments.Replace('\', '/')
    $operationsDocker = $operations.Replace('\', '/')

    $lines = @(
        "CLEARPOCKET_SERVER_IMAGE=ghcr.io/firepika2000/budget-server",
        "CLEARPOCKET_SERVER_VERSION=$serverVersion",
        "CLEARPOCKET_BIND_ADDRESS=0.0.0.0",
        "CLEARPOCKET_PORT=8080",
        "CLEARPOCKET_DATABASE_STORAGE=$databaseDocker",
        "CLEARPOCKET_ATTACHMENTS_STORAGE=$attachmentsDocker",
        "CLEARPOCKET_OPERATIONS_STORAGE=$operationsDocker",
        "BUDGET_APP_ALLOWED_HOSTS=$hostName,localhost,127.0.0.1",
        "BUDGET_APP_DB_PASSWORD=$(New-UrlSafeSecret 36)",
        "BUDGET_APP_JWT_SECRET=$(New-UrlSafeSecret 48)",
        "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=$(New-UrlSafeSecret 32)"
    )
    $temporary = "$environmentFile.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $environmentFile
    Write-Host "Private configuration created. Keep the .env file with your encrypted backups; its secrets were not displayed."
}

$portSetting = @(Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match '^CLEARPOCKET_PORT=' })
if ($portSetting.Count -ne 1) { throw "Private configuration has an invalid server port setting." }
$serverPort = 0
if (-not [int]::TryParse($portSetting[0].Split('=', 2)[1], [ref] $serverPort) -or
    $serverPort -lt 1 -or $serverPort -gt 65535) {
    throw "Private configuration has an invalid server port setting."
}
$healthUrl = "http://127.0.0.1:$serverPort/api/v1/health"
$adminUrl = "http://127.0.0.1:$serverPort/admin"

function Invoke-ClearPocketCompose([string[]] $ComposeArguments) {
    & docker compose --env-file $environmentFile @ComposeArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose operation failed. Choose Diagnostics for support information."
    }
}

function Test-ClearPocketHealth {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 3
        return $response.StatusCode -eq 200
    } catch {
        return $false
    }
}

function Start-ClearPocketServer {
    Invoke-ClearPocketCompose @("config", "--quiet")
    Invoke-ClearPocketCompose @("up", "-d")
    Write-Host "Waiting for ClearPocket Server to become healthy..."
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if (Test-ClearPocketHealth) {
            Write-Host "ClearPocket Server is healthy."
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Containers started, but the server did not become healthy within two minutes. Choose Diagnostics and Recent logs."
}

function Show-ClearPocketStatus {
    Invoke-ClearPocketCompose @("ps")
    if (Test-ClearPocketHealth) {
        Write-Host "API health: healthy"
    } else {
        Write-Host "API health: unreachable"
    }
}

function Write-ClearPocketDiagnostics {
    $dockerVersion = (& docker version --format "{{.Server.Version}}" 2>$null)
    $composeVersion = (& docker compose version --short 2>$null)
    $services = (& docker compose --env-file $environmentFile ps --format json 2>$null)
    $report = [ordered]@{
        GeneratedAt = [DateTimeOffset]::UtcNow.ToString("o")
        ServerVersion = $serverVersion
        DockerServer = $dockerVersion
        DockerCompose = $composeVersion
        ApiHealth = if (Test-ClearPocketHealth) { "healthy" } else { "unreachable" }
        Services = $services
    }
    $destination = Join-Path $PSScriptRoot "clearpocket-diagnostics.json"
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8
    Write-Host "Redacted diagnostics written to $destination"
    Write-Host "The report contains runtime status, never configuration secrets or application data."
}

function Install-ClearPocketAutoStart {
    $taskName = "ClearPocket Server"
    $powershell = Join-Path $PSHOME "powershell.exe"
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Operation Start"
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trigger.Delay = "PT1M"
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Description "Start the private ClearPocket household server after Docker Desktop is available." `
        -Force | Out-Null
    Write-Host "Automatic startup enabled for this Windows account."
    Write-Host "Keep Docker Desktop's 'Start Docker Desktop when you sign in' setting enabled."
}

function Remove-ClearPocketAutoStart {
    $task = Get-ScheduledTask -TaskName "ClearPocket Server" -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName "ClearPocket Server" -Confirm:$false
    }
    Write-Host "Automatic startup disabled. Server data and configuration were not changed."
}

function Import-ClearPocketLocalDevice {
    Write-Host ""
    Write-Host "Move an iPhone Local Device budget to this server"
    Write-Host "This initializes a new, empty server from an authenticated .clearpocketbackup folder."
    Write-Host "It does not erase the iPhone copy. Existing server data is never merged or replaced."
    $enteredPath = Read-Host "Full path to the .clearpocketbackup folder"
    if ([string]::IsNullOrWhiteSpace($enteredPath)) {
        throw "No Local Device backup folder was selected."
    }
    $resolved = Resolve-Path -LiteralPath $enteredPath -ErrorAction Stop
    if ($resolved.Count -ne 1) {
        throw "Select exactly one Local Device backup folder."
    }
    $package = Get-Item -LiteralPath $resolved.Path -Force
    if (-not $package.PSIsContainer -or ($package.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The Local Device backup must be a regular, non-linked folder."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $package.FullName "manifest.json") -PathType Leaf)) {
        throw "The selected folder is not a complete Local Device backup package."
    }
    $confirmation = Read-Host "Type IMPORT to stop this server and verify the transfer"
    if ($confirmation -cne "IMPORT") {
        Write-Host "Import cancelled. The server and iPhone data were not changed."
        return
    }

    Invoke-ClearPocketCompose @("stop", "api")
    Invoke-ClearPocketCompose @("up", "-d", "database")
    $mount = "$($package.FullName):/import/package:ro"
    try {
        Invoke-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root",
            "--volume", $mount,
            "api", "sh", "-c",
            "cp -R /import/package /tmp/local-device-package && " +
            "chown -R budget:budget /tmp/local-device-package && " +
            "exec su -s /bin/sh budget -c 'alembic upgrade head && " +
            "python scripts/local_device_transfer.py /tmp/local-device-package --server-environment'"
        )
    } catch {
        Write-Warning "Import failed. The API remains stopped so a partial authority is never served."
        Write-Warning "The source iPhone backup was mounted read-only and was not changed."
        throw
    }
    Start-ClearPocketServer
    Write-Host "Local Device budget imported and verified. Keep the iPhone backup until you have tested this server and created a server backup."
}

function Install-ClearPocketBackupSchedule {
    $backupScript = Join-Path $PSScriptRoot "backup-windows.ps1"
    if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
        throw "Windows backup support is missing. Download the complete server package again."
    }
    $recipients = @(Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match '^BUDGET_APP_BACKUP_AGE_RECIPIENT=age1[0-9a-z]+$' })
    if ($recipients.Count -ne 1) {
        throw "Create one successful interactive backup and preserve its recovery identity before scheduling."
    }
    $defaultBackup = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "ClearPocket Backups"
    $backupDirectory = Read-Host "Scheduled encrypted-backup folder [$defaultBackup]"
    if ([string]::IsNullOrWhiteSpace($backupDirectory)) { $backupDirectory = $defaultBackup }
    $backupDirectory = [IO.Path]::GetFullPath($backupDirectory)
    if ($backupDirectory -match '[\r\n"]') { throw "Scheduled backup folder contains unsupported characters." }
    if ($backupScript -match '[\r\n"]' -or $environmentFile -match '[\r\n"]') {
        throw "ClearPocket was installed in a path that Task Scheduler cannot safely use."
    }
    New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
    $timeText = Read-Host "Daily backup time in 24-hour HH:mm format [03:00]"
    if ([string]::IsNullOrWhiteSpace($timeText)) { $timeText = "03:00" }
    $backupTime = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
        $timeText, "HH:mm", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref] $backupTime
    )) { throw "Backup time must use 24-hour HH:mm format." }

    $powershell = Join-Path $PSHOME "powershell.exe"
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
        "-File `"$backupScript`" -EnvironmentFile `"$environmentFile`" " +
        "-Operation Scheduled -BackupDirectory `"$backupDirectory`""
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Daily -At $backupTime
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName "ClearPocket Server Backup" -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "Create a coordinated encrypted ClearPocket Server backup." -Force | Out-Null
    Write-Host "Daily encrypted backup scheduled for $timeText."
    Write-Host "The task contains paths only. Recovery and server credentials are not stored in Task Scheduler."
}

function Remove-ClearPocketBackupSchedule {
    $task = Get-ScheduledTask -TaskName "ClearPocket Server Backup" -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName "ClearPocket Server Backup" -Confirm:$false
    }
    Write-Host "Scheduled backup disabled. Existing generations and the recovery identity were preserved."
}

function Show-ClearPocketBackupSchedule {
    $task = Get-ScheduledTask -TaskName "ClearPocket Server Backup" -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "No scheduled ClearPocket backup is installed."
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName "ClearPocket Server Backup"
    Write-Host "Backup task state: $($task.State)"
    Write-Host "Next run: $($info.NextRunTime)"
    Write-Host "Last result: $($info.LastTaskResult)"
}

function Update-ClearPocketServer {
    if ($serverVersion -eq "edge") {
        throw "This folder is not an immutable release bundle. Download a versioned ClearPocket Server package."
    }
    $versionSettings = @(Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match '^CLEARPOCKET_SERVER_VERSION=' })
    $imageSettings = @(Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match '^CLEARPOCKET_SERVER_IMAGE=' })
    if ($versionSettings.Count -ne 1 -or $imageSettings.Count -ne 1) {
        throw "Private configuration has an ambiguous server image or version."
    }
    $currentVersion = $versionSettings[0].Split('=', 2)[1]
    $image = $imageSettings[0].Split('=', 2)[1]
    if ($currentVersion -eq "edge" -or $currentVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Update requires a currently pinned immutable server version."
    }
    if ($image -notmatch '^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,254}$') {
        throw "Private configuration has an invalid server image."
    }
    if ($currentVersion -eq $serverVersion) {
        Write-Host "ClearPocket Server is already configured for version $serverVersion."
        return
    }
    $confirmation = Read-Host "Type UPDATE to back up and apply server version $serverVersion"
    if ($confirmation -cne "UPDATE") {
        Write-Host "Update cancelled. Server configuration and data were not changed."
        return
    }
    $backupScript = Join-Path $PSScriptRoot "backup-windows.ps1"
    if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
        throw "Windows backup support is missing. Download the complete server package again."
    }
    & $backupScript -EnvironmentFile $environmentFile
    if (-not $?) { throw "Required pre-update backup did not complete." }

    & docker pull "${image}:$serverVersion"
    if ($LASTEXITCODE -ne 0) {
        throw "Version $serverVersion could not be downloaded. Configuration and running services were not changed."
    }
    $lines = @(Get-Content -LiteralPath $environmentFile | ForEach-Object {
        if ($_ -match '^CLEARPOCKET_SERVER_VERSION=') { "CLEARPOCKET_SERVER_VERSION=$serverVersion" } else { $_ }
    })
    $temporary = "$environmentFile.$([Guid]::NewGuid().ToString('N')).update"
    try {
        [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $environmentFile -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    try {
        Start-ClearPocketServer
    } catch {
        try { Invoke-ClearPocketCompose @("stop", "api") } catch { }
        throw "Version $serverVersion did not become healthy. The pre-update backup was preserved; automatic downgrade is disabled after migrations."
    }
    Write-Host "ClearPocket Server updated and healthy at version $serverVersion."
}

if ($Operation -eq "Start") {
    Start-ClearPocketServer
    exit 0
}

Write-Host ""
Write-Host "ClearPocket Server Manager"
Write-Host "  1. Start server and open setup"
Write-Host "  2. Show status"
Write-Host "  3. Stop server (keep all data)"
Write-Host "  4. Create redacted diagnostics"
Write-Host "  5. Show recent logs"
Write-Host "  6. Start automatically when I sign in"
Write-Host "  7. Disable automatic startup"
Write-Host "  8. Move an iPhone Local Device budget to this server"
Write-Host "  9. Create an encrypted server backup"
Write-Host " 10. Restore an encrypted backup into this empty server"
Write-Host " 11. Schedule daily encrypted backups"
Write-Host " 12. Disable scheduled backups"
Write-Host " 13. Show backup schedule status"
Write-Host " 14. Apply this downloaded server version"
Write-Host ""
$choice = if ($newInstall) { "1" } else { Read-Host "Choose an option [1]" }
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

switch ($choice) {
    "1" {
        Start-ClearPocketServer
        Start-Process $adminUrl
    }
    "2" { Show-ClearPocketStatus }
    "3" {
        Invoke-ClearPocketCompose @("stop")
        Write-Host "ClearPocket Server stopped. Database, attachments, and private configuration were preserved."
    }
    "4" { Write-ClearPocketDiagnostics }
    "5" { Invoke-ClearPocketCompose @("logs", "--no-color", "--tail", "200") }
    "6" { Install-ClearPocketAutoStart }
    "7" { Remove-ClearPocketAutoStart }
    "8" { Import-ClearPocketLocalDevice }
    "9" {
        $backupScript = Join-Path $PSScriptRoot "backup-windows.ps1"
        if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
            throw "Windows backup support is missing. Download the complete server package again."
        }
        & $backupScript -EnvironmentFile $environmentFile
        if (-not $?) { throw "Windows backup did not complete." }
    }
    "10" {
        $restoreScript = Join-Path $PSScriptRoot "restore-windows.ps1"
        if (-not (Test-Path -LiteralPath $restoreScript -PathType Leaf)) {
            throw "Windows recovery support is missing. Download the complete server package again."
        }
        & $restoreScript -EnvironmentFile $environmentFile
        if (-not $?) { throw "Windows recovery did not complete." }
    }
    "11" { Install-ClearPocketBackupSchedule }
    "12" { Remove-ClearPocketBackupSchedule }
    "13" { Show-ClearPocketBackupSchedule }
    "14" { Update-ClearPocketServer }
    default { throw "Unknown option. Run the launcher again and choose 1 through 14." }
}
