param(
    [ValidateSet("Interactive", "Configure", "Start", "Open", "Status", "Stop", "Diagnostics", "Logs", "Backup", "Restore", "ImportLocal")]
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

function Get-PinnedReleaseImage {
    $metadata = Join-Path $PSScriptRoot "RELEASE-METADATA.txt"
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return $null }
    $versions = @(Get-Content -LiteralPath $metadata | Where-Object { $_ -match '^version=' })
    $images = @(Get-Content -LiteralPath $metadata | Where-Object { $_ -match '^image=' })
    if ($versions.Count -ne 1 -or $versions[0].Split('=', 2)[1] -ne $serverVersion) {
        throw "Release metadata does not match this server package version."
    }
    if ($images.Count -ne 1) { throw "Release metadata has an ambiguous image digest." }
    $reference = $images[0].Split('=', 2)[1]
    if ($reference -notmatch '^ghcr\.io/firepika2000/budget-server@sha256:[0-9a-f]{64}$') {
        throw "Release metadata has an invalid server image digest."
    }
    return $reference
}

function Install-PinnedReleaseImage([string] $TaggedImage) {
    $pinned = Get-PinnedReleaseImage
    if ($null -eq $pinned) {
        & docker pull $TaggedImage
    } else {
        & docker pull $pinned
        if ($LASTEXITCODE -eq 0) { & docker tag $pinned $TaggedImage }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "The immutable ClearPocket Server image could not be downloaded."
    }
}

function ConvertTo-PublicHost([string] $Value) {
    $hostName = $Value.Trim().TrimEnd('.').ToLowerInvariant()
    $address = $null
    if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName.Length -gt 253 -or
        $hostName -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$' -or
        [Net.IPAddress]::TryParse($hostName, [ref] $address) -or
        $hostName -eq "localhost" -or $hostName.EndsWith(".localhost")) {
        throw "Public host must be a fully qualified DNS hostname, without a URL, path, or port."
    }
    return $hostName
}

function Read-PrivateValue([string] $Prompt, [bool] $AllowEmpty = $false) {
    $secure = Read-Host $Prompt -AsSecureString
    if ($secure.Length -eq 0 -and $AllowEmpty) { return "" }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    if ([string]::IsNullOrWhiteSpace($value) -or $value -ne $value.Trim() -or $value -match '[\x00-\x1f]') {
        throw "Private Dropbox value is empty or contains unsupported whitespace."
    }
    return $value
}

function Set-PrivateEnvironmentSetting([string] $Name, [string] $Value) {
    $matches = @(Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" })
    if ($matches.Count -gt 1) { throw "Private configuration contains duplicate $Name settings." }
    $found = $false
    $lines = @(Get-Content -LiteralPath $environmentFile | ForEach-Object {
        if ($_ -match "^$([regex]::Escape($Name))=") { $found = $true; "$Name=$Value" } else { $_ }
    })
    if (-not $found) { $lines += "$Name=$Value" }
    $temporary = "$environmentFile.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $environmentFile -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker Desktop is required. Install it, start it, then run this launcher again."
}
$dockerReady = $false
$attemptLimit = if ($Operation -in @("Configure", "Start", "Open")) { 60 } else { 1 }
for ($attempt = 0; $attempt -lt $attemptLimit; $attempt++) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { $dockerReady = $true; break }
    if ($attempt + 1 -lt $attemptLimit) { Start-Sleep -Seconds 2 }
}
if (-not $dockerReady) { throw "Docker Desktop is installed but is not running." }

$environmentFile = Join-Path $PSScriptRoot ".env"
$newInstall = -not (Test-Path -LiteralPath $environmentFile)
if ($newInstall -and $Operation -notin @("Configure", "Interactive")) {
    throw "ClearPocket Server needs first-time setup before this action is available."
}
if ($newInstall) {
    if ($Operation -eq "Configure") {
        $publicHostInput = $env:CLEARPOCKET_SETUP_PUBLIC_HOST
        $storageRoot = $env:CLEARPOCKET_SETUP_STORAGE_ROOT
    } else {
        Write-Host "ClearPocket Server first-time setup"
        Write-Host "Enter a public DNS hostname for automatic HTTPS and iPhone pairing."
        Write-Host "The hostname must already point to this PC; your router must send TCP 80 and 443 here."
        Write-Host "Leave it blank for a private, PC-only installation. Never expose raw port 8080."
        $publicHostInput = Read-Host "Public HTTPS hostname [local only]"
        $defaultRoot = Join-Path $env:LOCALAPPDATA "ClearPocket Server\Data"
        $storageRoot = Read-Host "Data folder [$defaultRoot]"
        if ([string]::IsNullOrWhiteSpace($storageRoot)) { $storageRoot = $defaultRoot }
    }
    $publicHost = ""
    if (-not [string]::IsNullOrWhiteSpace($publicHostInput)) {
        $publicHost = ConvertTo-PublicHost $publicHostInput
    }

    $defaultRoot = Join-Path $env:LOCALAPPDATA "ClearPocket Server\Data"
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
    $allowedHosts = if ($publicHost) { "localhost,127.0.0.1,$publicHost" } else { "localhost,127.0.0.1" }

    $lines = @(
        "CLEARPOCKET_SERVER_IMAGE=ghcr.io/firepika2000/budget-server",
        "CLEARPOCKET_SERVER_VERSION=$serverVersion",
        "CLEARPOCKET_BIND_ADDRESS=127.0.0.1",
        "CLEARPOCKET_PORT=8080",
        "CLEARPOCKET_DATABASE_STORAGE=$databaseDocker",
        "CLEARPOCKET_ATTACHMENTS_STORAGE=$attachmentsDocker",
        "CLEARPOCKET_OPERATIONS_STORAGE=$operationsDocker",
        "BUDGET_APP_ALLOWED_HOSTS=$allowedHosts",
        "BUDGET_APP_DB_PASSWORD=$(New-UrlSafeSecret 36)",
        "BUDGET_APP_JWT_SECRET=$(New-UrlSafeSecret 48)",
        "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=$(New-UrlSafeSecret 32)"
    )
    if ($publicHost) {
        $lines += @(
            "COMPOSE_PROFILES=tls",
            "CLEARPOCKET_PUBLIC_HOST=$publicHost",
            "BUDGET_APP_PAIRING_PUBLIC_URL=https://$publicHost",
            "BUDGET_APP_FORWARDED_ALLOW_IPS=*"
        )
    }
    $temporary = "$environmentFile.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
        # Do not publish a configured installation until the immutable application image is local.
        # A failed download therefore returns to first-time setup instead of leaving an unusable
        # authority that later Compose commands could resolve through a mutable tag.
        Install-PinnedReleaseImage "ghcr.io/firepika2000/budget-server:$serverVersion"
        Move-Item -LiteralPath $temporary -Destination $environmentFile
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Private configuration created. Keep the .env file with your encrypted backups; its secrets were not displayed."
    if ($Operation -eq "Configure") { $Operation = "Open" }
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
$publicUrlSettings = @(Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match '^BUDGET_APP_PAIRING_PUBLIC_URL=' })
if ($publicUrlSettings.Count -gt 1) { throw "Private configuration has duplicate public URL settings." }
if ($publicUrlSettings.Count -eq 1) {
    $publicOrigin = $publicUrlSettings[0].Split('=', 2)[1]
    if ($publicOrigin -notmatch '^https://[a-z0-9.-]+$') {
        throw "Private configuration has an invalid public HTTPS origin."
    }
    $adminUrl = "$publicOrigin/admin"
}

function Invoke-ClearPocketCompose([string[]] $ComposeArguments) {
    & docker compose --env-file $environmentFile @ComposeArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose operation failed. Choose Diagnostics for support information."
    }
}

function Invoke-ClearPocketComposeWithPrivateInput([string] $PrivateInput, [string[]] $ComposeArguments) {
    try {
        $PrivateInput | & docker compose --env-file $environmentFile @ComposeArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Docker Compose private-input operation failed. Choose Diagnostics for support information."
        }
    } finally {
        Remove-Variable PrivateInput -ErrorAction SilentlyContinue
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
            if ($publicUrlSettings.Count -eq 1) {
                Write-Host "Secure iPhone endpoint: $publicOrigin"
            }
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

function Configure-ClearPocketDropboxBackup {
    Write-Host ""
    Write-Host "Configure encrypted Dropbox backup publication"
    Write-Host "Dropbox stores only completed age-encrypted generations, never the live database."
    Write-Host "Use a least-privilege Dropbox app-folder grant. Private values will not be displayed."
    $mode = Read-Host "Use 1 for a temporary access token or 2 for durable refresh credentials [2]"
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "2" }
    $credentialLines = @()
    if ($mode -eq "1") {
        $credentialLines += "BUDGET_APP_DROPBOX_ACCESS_TOKEN=$(Read-PrivateValue 'Dropbox access token')"
    } elseif ($mode -eq "2") {
        $credentialLines += "BUDGET_APP_DROPBOX_REFRESH_TOKEN=$(Read-PrivateValue 'Dropbox refresh token')"
        $credentialLines += "BUDGET_APP_DROPBOX_APP_KEY=$(Read-PrivateValue 'Dropbox app key')"
        $secret = Read-PrivateValue "Dropbox app secret (leave blank for a PKCE/native app)" $true
        if ($secret) { $credentialLines += "BUDGET_APP_DROPBOX_APP_SECRET=$secret" }
    } else {
        throw "Choose 1 or 2 for the Dropbox credential type."
    }
    $folder = Read-Host "Dropbox app-folder path [/Backups]"
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = "/Backups" }
    if ($folder -notmatch '^/(?!$)[A-Za-z0-9._/-]+$') {
        throw "Dropbox folder must be a non-root app-folder path using letters, numbers, dots, dashes, or underscores."
    }
    $credentialFile = Join-Path $PSScriptRoot "dropbox.env"
    $temporary = "$credentialFile.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllLines($temporary, $credentialLines, [Text.UTF8Encoding]::new($false))
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetOwner($identity.User)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $temporary -AclObject $acl
        Move-Item -LiteralPath $temporary -Destination $credentialFile -Force
        Set-Acl -LiteralPath $credentialFile -AclObject $acl
        Set-PrivateEnvironmentSetting "BUDGET_APP_DROPBOX_FOLDER" $folder
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        $credentialLines = @()
        Remove-Variable secret -ErrorAction SilentlyContinue
    }
    Write-Host "Dropbox publication configured. The next manual or scheduled backup will test and use it."
    Write-Warning "Keep the age recovery identity on a separate protected device, not in Dropbox."
}

function Disable-ClearPocketDropboxBackup {
    $credentialFile = Join-Path $PSScriptRoot "dropbox.env"
    if (-not (Test-Path -LiteralPath $credentialFile -PathType Leaf)) {
        Write-Host "Dropbox backup publication is not configured."
        return
    }
    $confirmation = Read-Host "Type DISCONNECT to remove the local Dropbox grant (remote backups remain)"
    if ($confirmation -cne "DISCONNECT") {
        Write-Host "Dropbox backup publication was not changed."
        return
    }
    Remove-Item -LiteralPath $credentialFile -Force
    Write-Host "Dropbox backup publication disabled. Existing local and remote generations were preserved."
}

function Import-ClearPocketLocalDevice(
    [string] $PackagePath = "",
    [string] $Confirmation = "",
    [string] $CredentialsInput = ""
) {
    Write-Host ""
    Write-Host "Move an iPhone Local Device budget to this server"
    Write-Host "This initializes a new, empty server from an authenticated .clearpocketbackup folder."
    Write-Host "It does not erase the iPhone copy. Existing server data is never merged or replaced."
    $enteredPath = $PackagePath
    if ([string]::IsNullOrWhiteSpace($enteredPath)) {
        $enteredPath = Read-Host "Full path to the .clearpocketbackup folder"
    }
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
    $confirmationValue = $Confirmation
    if ([string]::IsNullOrWhiteSpace($confirmationValue)) {
        $confirmationValue = Read-Host "Type IMPORT to stop this server and verify the transfer"
    }
    if ($confirmationValue -cne "IMPORT") {
        Write-Host "Import cancelled. The server and iPhone data were not changed."
        return
    }

    Invoke-ClearPocketCompose @("stop", "api")
    Invoke-ClearPocketCompose @("up", "-d", "database")
    $mount = "$($package.FullName):/import/package:ro"
    try {
        $arguments = @("run", "--rm", "--no-deps", "--user", "root", "--volume", $mount)
        $command = "cp -R /import/package /tmp/local-device-package && " +
            "chown -R budget:budget /tmp/local-device-package && " +
            "exec su -s /bin/sh budget -c 'alembic upgrade head && " +
            "python scripts/local_device_transfer.py /tmp/local-device-package --server-environment"
        if ([string]::IsNullOrEmpty($CredentialsInput)) {
            $arguments += @("api", "sh", "-c", $command + "'")
            Invoke-ClearPocketCompose $arguments
        } else {
            $arguments += @("-T", "api", "sh", "-c", $command + " --server-credentials-stdin'")
            Invoke-ClearPocketComposeWithPrivateInput $CredentialsInput $arguments
        }
    } catch {
        Write-Warning "Import failed. The API remains stopped so a partial authority is never served."
        Write-Warning "The source iPhone backup was mounted read-only and was not changed."
        throw
    }
    Start-ClearPocketServer
    Write-Host "Local Device budget imported and verified. Keep the iPhone backup until you have tested this server and created a server backup."
}

function Import-ClearPocketPortableArchive {
    Write-Host ""
    Write-Host "Move an encrypted portable household into this empty server"
    Write-Host "This validates the complete provider-neutral archive and never merges or replaces existing server data."
    $archiveInput = Read-Host "Full path to the encrypted portable .tar.gz.age archive"
    if ([string]::IsNullOrWhiteSpace($archiveInput)) { throw "No portable archive was selected." }
    $archive = Get-Item -LiteralPath ([IO.Path]::GetFullPath($archiveInput)) -Force
    if ($archive.PSIsContainer -or ($archive.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        -not $archive.Name.EndsWith(".tar.gz.age", [StringComparison]::OrdinalIgnoreCase)) {
        throw "The portable archive must be a regular, non-linked .tar.gz.age file."
    }
    $identityInput = Read-Host "Full path to the age identity (leave blank for a passphrase archive)"
    $identity = $null
    if (-not [string]::IsNullOrWhiteSpace($identityInput)) {
        $identity = Get-Item -LiteralPath ([IO.Path]::GetFullPath($identityInput)) -Force
        if ($identity.PSIsContainer -or ($identity.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "The age identity must be a regular, non-linked file."
        }
    }
    $confirmation = Read-Host "Type IMPORT to stop this server and initialize it from the portable archive"
    if ($confirmation -cne "IMPORT") {
        Write-Host "Import cancelled. The server and portable archive were not changed."
        return
    }

    Invoke-ClearPocketCompose @("stop", "api")
    Invoke-ClearPocketCompose @("up", "-d", "database")
    $arguments = @(
        "run", "--rm", "--no-deps", "--user", "root",
        "--volume", "$($archive.FullName):/import/archive.age:ro"
    )
    $prepare = "install -m 600 -o budget -g budget /import/archive.age /tmp/archive.age"
    if ($null -ne $identity) {
        $arguments += @(
            "--volume", "$($identity.FullName):/import/identity.txt:ro",
            "--env", "BUDGET_APP_BACKUP_AGE_IDENTITY=/tmp/identity.txt"
        )
        $prepare += " && install -m 600 -o budget -g budget /import/identity.txt /tmp/identity.txt"
    }
    $arguments += @(
        "api", "sh", "-c",
        "$prepare && exec su -s /bin/sh budget -c 'alembic upgrade head && " +
        "python scripts/portable_import.py /tmp/archive.age --server-environment'"
    )
    try {
        Invoke-ClearPocketCompose $arguments
    } catch {
        Write-Warning "Portable import failed. The API remains stopped so a partial authority is never served."
        Write-Warning "The source archive and identity were mounted read-only and were not changed."
        throw
    }
    Start-ClearPocketServer
    Write-Host "Portable household imported and verified. All users must sign in again against this new authority."
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

    try {
        Install-PinnedReleaseImage "${image}:$serverVersion"
    } catch {
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

if ($Operation -ne "Interactive") {
    switch ($Operation) {
        "Start" { Start-ClearPocketServer }
        "Open" {
            Start-ClearPocketServer
            Start-Process $adminUrl
        }
        "Status" { Show-ClearPocketStatus }
        "Stop" {
            Invoke-ClearPocketCompose @("stop")
            Write-Host "ClearPocket Server stopped. Database, attachments, and private configuration were preserved."
        }
        "Diagnostics" { Write-ClearPocketDiagnostics }
        "Logs" { Invoke-ClearPocketCompose @("logs", "--no-color", "--tail", "200") }
        "Backup" {
            $backupScript = Join-Path $PSScriptRoot "backup-windows.ps1"
            if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
                throw "Windows backup support is missing. Download the complete server package again."
            }
            $backupArguments = @{
                EnvironmentFile = $environmentFile
                Operation = "Manager"
                BackupDirectory = $env:CLEARPOCKET_BACKUP_DIRECTORY
                RecoveryDirectory = $env:CLEARPOCKET_RECOVERY_DIRECTORY
            }
            if ($env:CLEARPOCKET_ALLOW_EXISTING_RECOVERY -ceq "USE") {
                $backupArguments["AllowExistingRecoveryIdentity"] = $true
            }
            & $backupScript @backupArguments
            if (-not $?) { throw "Windows backup did not complete." }
        }
        "Restore" {
            $restoreScript = Join-Path $PSScriptRoot "restore-windows.ps1"
            if (-not (Test-Path -LiteralPath $restoreScript -PathType Leaf)) {
                throw "Windows recovery support is missing. Download the complete server package again."
            }
            & $restoreScript -EnvironmentFile $environmentFile -Operation Manager `
                -ArchivePath $env:CLEARPOCKET_RESTORE_ARCHIVE `
                -IdentityPath $env:CLEARPOCKET_RESTORE_IDENTITY `
                -Confirmation $env:CLEARPOCKET_RESTORE_CONFIRMATION
            if (-not $?) { throw "Windows recovery did not complete." }
        }
        "ImportLocal" {
            $privateInput = [Console]::In.ReadToEnd()
            if ([string]::IsNullOrWhiteSpace($privateInput) -or $privateInput.Length -gt 16384 -or
                $privateInput.Contains([char] 0)) {
                throw "Private Local Device transfer credentials are missing or invalid."
            }
            try {
                Import-ClearPocketLocalDevice `
                    -PackagePath $env:CLEARPOCKET_LOCAL_IMPORT_PACKAGE `
                    -Confirmation $env:CLEARPOCKET_LOCAL_IMPORT_CONFIRMATION `
                    -CredentialsInput $privateInput
            } finally {
                Remove-Variable privateInput -ErrorAction SilentlyContinue
            }
        }
        default { throw "Unsupported non-interactive manager operation." }
    }
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
Write-Host " 15. Move an encrypted portable household to this server"
Write-Host " 16. Configure Dropbox backup publication"
Write-Host " 17. Disable Dropbox backup publication"
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
    "15" { Import-ClearPocketPortableArchive }
    "16" { Configure-ClearPocketDropboxBackup }
    "17" { Disable-ClearPocketDropboxBackup }
    default { throw "Unknown option. Run the launcher again and choose 1 through 17." }
}
