[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $EnvironmentFile,
    [ValidateSet("Interactive", "Manager", "Scheduled")]
    [string] $Operation = "Interactive",
    [string] $BackupDirectory = "",
    [string] $RecoveryDirectory = "",
    [switch] $AllowExistingRecoveryIdentity
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
$EnvironmentFile = [IO.Path]::GetFullPath($EnvironmentFile)
if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf)) {
    throw "Private server configuration was not found."
}
$lockPath = Join-Path $PSScriptRoot ".clearpocket-backup.lock"
try {
    $lockStream = [IO.File]::Open(
        $lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None
    )
} catch [IO.IOException] {
    throw "Another ClearPocket backup is already running."
}
try {

function Invoke-ClearPocketCompose([string[]] $ComposeArguments) {
    & docker compose --env-file $EnvironmentFile @ComposeArguments
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose backup operation failed." }
}

function Read-ClearPocketCompose([string[]] $ComposeArguments) {
    $value = & docker compose --env-file $EnvironmentFile @ComposeArguments
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose backup operation failed." }
    return (($value | ForEach-Object { [string] $_ }) -join "`n").Trim()
}

function Write-PrivateText([string] $Path, [string] $Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Save-BackupStatus([string] $State, [string] $Archive = "", [string] $DestinationJson = "") {
    if ($DestinationJson) {
        if ($State -ne "healthy" -or -not (Test-Path -LiteralPath $Archive -PathType Leaf) -or
            -not (Test-Path -LiteralPath $DestinationJson -PathType Leaf)) {
            throw "Verified destination health requires a completed local generation and metadata."
        }
        $archiveName = [IO.Path]::GetFileName($Archive)
        Invoke-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root",
            "--volume", "${Archive}:/input/${archiveName}:ro",
            "--volume", "${DestinationJson}:/input/destination.json:ro",
            "api", "python", "scripts/backup_health.py", "healthy", "/input/$archiveName",
            "--reported-path", $Archive, "--destination-json", "/input/destination.json"
        )
        Invoke-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root", "api", "sh", "-c",
            'chown budget:budget "$BUDGET_APP_BACKUP_STATUS_PATH"'
        )
        return
    }
    $status = [ordered]@{
        state = $State
        completed_at = [DateTimeOffset]::UtcNow.ToString("o")
    }
    if ($Archive -and (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        $file = Get-Item -LiteralPath $Archive
        $status["archive"] = $file.FullName
        $status["size"] = $file.Length
        $status["sha256"] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $status["destination"] = [ordered]@{
            destination = "local_generation"
            path = $file.FullName
        }
        if ($State -eq "publication_failed") {
            $status["error"] = "Off-device backup publication failed"
        }
    } else {
        $status["error"] = "Backup capture failed"
    }
    $statusFile = Join-Path $env:TEMP "clearpocket-backup-status-$([Guid]::NewGuid().ToString('N')).json"
    try {
        Write-PrivateText $statusFile (($status | ConvertTo-Json -Depth 4) + "`n")
        $mount = "${statusFile}:/input/backup-status.json:ro"
        Invoke-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root", "--volume", $mount,
            "api", "sh", "-c",
            "install -m 600 -o budget -g budget /input/backup-status.json " +
            "/var/lib/budget-app/operations/backup-status.json"
        )
    } finally {
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }
}

function Read-EnvironmentSetting([string] $Name) {
    $settings = @(Get-Content -LiteralPath $EnvironmentFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" })
    if ($settings.Count -gt 1) { throw "Private configuration contains duplicate $Name settings." }
    if ($settings.Count -eq 0) { return "" }
    return $settings[0].Split('=', 2)[1].Trim()
}

function Add-EnvironmentSetting([string] $Name, [string] $Value) {
    if (Read-EnvironmentSetting $Name) { throw "Private configuration already contains $Name." }
    $lines = @(Get-Content -LiteralPath $EnvironmentFile)
    $temporary = "$EnvironmentFile.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllLines($temporary, @($lines + "$Name=$Value"), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $EnvironmentFile -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BackupRetention([string] $Directory, [int] $Retention) {
    $generations = @(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object {
            $_.Name -match '^budget-[0-9]{8}T[0-9]{6}Z\.tar\.gz\.age$' -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        } |
        Sort-Object -Property LastWriteTimeUtc -Descending)
    foreach ($generation in @($generations | Select-Object -Skip $Retention)) {
        Remove-Item -LiteralPath $generation.FullName -Force
    }
}

$recipient = Read-EnvironmentSetting "BUDGET_APP_BACKUP_AGE_RECIPIENT"
if (-not $recipient) {
    if ($Operation -eq "Scheduled") {
        throw "Run one interactive backup to create and preserve the recovery identity before scheduling."
    }
    Write-Host "ClearPocket encrypted-backup recovery setup"
    Write-Host "A private recovery identity will be created. Anyone with this file can decrypt your backup."
    $defaultRecovery = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "ClearPocket Recovery"
    if ([string]::IsNullOrWhiteSpace($RecoveryDirectory)) {
        if ($Operation -eq "Manager") { throw "Graphical backup requires a separate recovery-key folder." }
        $RecoveryDirectory = Read-Host "Separate recovery-key folder [$defaultRecovery]"
        if ([string]::IsNullOrWhiteSpace($RecoveryDirectory)) { $RecoveryDirectory = $defaultRecovery }
    }
    $recoveryDirectory = [IO.Path]::GetFullPath($RecoveryDirectory)
    New-Item -ItemType Directory -Force -Path $recoveryDirectory | Out-Null
    $identity = Join-Path $recoveryDirectory "clearpocket-recovery-key.txt"
    if (Test-Path -LiteralPath $identity) {
        $reuseApproved = $AllowExistingRecoveryIdentity.IsPresent
        if ($Operation -ne "Manager") {
            $reuse = Read-Host "A recovery identity already exists there. Type USE to adopt it without replacing it"
            $reuseApproved = $reuse -ceq "USE"
        }
        if (-not $reuseApproved) {
            throw "The existing recovery identity was not used or replaced."
        }
    } else {
        $recoveryMount = "${recoveryDirectory}:/recovery"
        Invoke-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root", "--volume", $recoveryMount,
            "--entrypoint", "age-keygen", "api", "-o", "/recovery/clearpocket-recovery-key.txt"
        )
    }
    $recipient = Read-ClearPocketCompose @(
        "run", "--rm", "--no-deps", "--volume", "${identity}:/recovery/key.txt:ro",
        "--entrypoint", "age-keygen", "api", "-y", "/recovery/key.txt"
    )
    if ($recipient -notmatch '^age1[0-9a-z]+$') {
        throw "The generated backup recovery identity could not be validated."
    }
    Add-EnvironmentSetting "BUDGET_APP_BACKUP_AGE_RECIPIENT" $recipient
    Write-Host "Recovery identity created at $identity"
    Write-Warning "Copy that identity to a separate protected device or offline location. Do not store the only copy beside this server."
}
if ($recipient -notmatch '^age1[0-9a-z]+$') {
    throw "BUDGET_APP_BACKUP_AGE_RECIPIENT is invalid."
}
$retentionText = Read-EnvironmentSetting "BUDGET_APP_BACKUP_RETENTION"
if (-not $retentionText) { $retentionText = "10" }
$retention = 0
if (-not [int]::TryParse($retentionText, [ref] $retention) -or $retention -lt 1) {
    throw "BUDGET_APP_BACKUP_RETENTION must be a positive integer."
}
$dropboxCredentials = Join-Path $PSScriptRoot "dropbox.env"
$dropboxFolder = Read-EnvironmentSetting "BUDGET_APP_DROPBOX_FOLDER"
if (-not $dropboxFolder) { $dropboxFolder = "/Backups" }
if ($dropboxFolder -notmatch '^/(?!$)[A-Za-z0-9._/-]+$') {
    throw "BUDGET_APP_DROPBOX_FOLDER must name a non-root Dropbox folder."
}
if (Test-Path -LiteralPath $dropboxCredentials) {
    $dropboxItem = Get-Item -LiteralPath $dropboxCredentials -Force
    if ($dropboxItem.PSIsContainer -or ($dropboxItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Dropbox credential file must be a regular, non-linked file."
    }
}

$defaultBackup = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "ClearPocket Backups"
if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    if ($Operation -eq "Scheduled") { throw "Scheduled backup requires an explicit destination folder." }
    if ($Operation -eq "Manager") { throw "Graphical backup requires an explicit destination folder." }
    $BackupDirectory = Read-Host "Encrypted backup folder [$defaultBackup]"
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { $BackupDirectory = $defaultBackup }
}
$backupDirectory = [IO.Path]::GetFullPath($BackupDirectory)
New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'")
$filename = "budget-$timestamp.tar.gz.age"
$final = Join-Path $backupDirectory $filename
if (Test-Path -LiteralPath $final) { throw "A backup with this timestamp already exists." }
$partialName = ".$filename.$([Guid]::NewGuid().ToString('N')).partial"
$partial = Join-Path $backupDirectory $partialName
$staging = Join-Path $env:TEMP "clearpocket-backup-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging | Out-Null
New-Item -ItemType Directory -Path (Join-Path $staging "attachments") | Out-Null
$apiPaused = $false
$captureComplete = $false
$databaseTemporary = "/tmp/clearpocket-$([Guid]::NewGuid().ToString('N')).sql"

try {
    Write-Host "Capturing a coordinated encrypted backup. The API will pause briefly."
    $recoveryKey = Read-ClearPocketCompose @(
        "exec", "-T", "api", "sh", "-c",
        'if [ -n "${BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY:-}" ]; then printf "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s" "$BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"; else printf "BUDGET_APP_JWT_SECRET=%s" "$BUDGET_APP_JWT_SECRET"; fi'
    )
    if ($recoveryKey -notmatch '^BUDGET_APP_(ATTACHMENT_ENCRYPTION_KEY|JWT_SECRET)=\S+$') {
        throw "Attachment recovery material is invalid; no service was stopped."
    }
    Write-PrivateText (Join-Path $staging "attachment-key-recovery.env") ($recoveryKey + "`n")
    Remove-Variable recoveryKey

    Invoke-ClearPocketCompose @("stop", "api")
    $apiPaused = $true
    Invoke-ClearPocketCompose @(
        "exec", "-T", "database", "sh", "-c",
        "umask 077; pg_dump --clean --if-exists --no-owner --no-privileges --exclude-table-data=pairing_codes " +
        "-U budget -d budget > '$databaseTemporary'"
    )
    Invoke-ClearPocketCompose @("cp", "database:${databaseTemporary}", (Join-Path $staging "database.sql"))
    $revision = Read-ClearPocketCompose @(
        "exec", "-T", "database", "psql", "-At", "-U", "budget", "-d", "budget",
        "-c", "SELECT version_num FROM alembic_version"
    )
    if ($revision -notmatch '^[A-Za-z0-9_]+$') { throw "Database migration revision is invalid." }
    $metadata = "format_version=1`ncreated_at=$([DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`ndatabase_revision=$revision`n"
    Write-PrivateText (Join-Path $staging "BACKUP-METADATA") $metadata
    Invoke-ClearPocketCompose @("cp", "api:/var/lib/budget-app/attachments/.", (Join-Path $staging "attachments"))
    Invoke-ClearPocketCompose @(
        "run", "--rm", "--no-deps", "--volume", "${staging}/attachments:/capture/attachments:ro",
        "api", "python", "scripts/backup_capture.py", "validate-attachments", "/capture/attachments"
    )
    Invoke-ClearPocketCompose @("exec", "-T", "database", "rm", "-f", $databaseTemporary)
    Invoke-ClearPocketCompose @("start", "api")
    $apiPaused = $false

    Invoke-ClearPocketCompose @(
        "run", "--rm", "--no-deps", "--user", "root", "--volume", "${staging}:/capture",
        "api", "python", "scripts/backup_archive.py", "create-manifest", "/capture"
    )
    Invoke-ClearPocketCompose @(
        "run", "--rm", "--no-deps", "--user", "root",
        "--volume", "${staging}:/capture:ro", "--volume", "${backupDirectory}:/output",
        "--entrypoint", "sh", "api", "-c",
        "fifo=/tmp/clearpocket-backup-fifo; rm -f `$fifo; mkfifo `$fifo || exit 1; " +
        "tar -C /capture -czf - BACKUP-METADATA database.sql attachments " +
        "attachment-key-recovery.env MANIFEST.sha256 > `$fifo & tar_pid=`$!; " +
        "age --recipient '$recipient' --output '/output/$partialName' < `$fifo; " +
        "age_status=`$?; wait `$tar_pid; tar_status=`$?; rm -f `$fifo; " +
        "test `$age_status -eq 0 -a `$tar_status -eq 0"
    )
    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        throw "Encrypted backup publication did not produce a file."
    }
    Move-Item -LiteralPath $partial -Destination $final
    $captureComplete = $true
    if (Test-Path -LiteralPath $dropboxCredentials -PathType Leaf) {
        $dropboxResult = Read-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root",
            "--volume", "${final}:/input/${filename}:ro",
            "--volume", "${dropboxCredentials}:/input/dropbox.env:ro",
            "api", "sh", "-c",
            "install -m 600 -o budget -g budget /input/dropbox.env /tmp/dropbox.env && " +
            "exec python scripts/backup_destination.py publish /input/$filename " +
            '--destination dropbox --credentials-file /tmp/dropbox.env ' +
            '--dropbox-folder "$1" --keep "$2"',
            "dropbox-publish", $dropboxFolder, "$retention"
        )
        $destinationJson = Join-Path $staging "dropbox-publication.json"
        Write-PrivateText $destinationJson ($dropboxResult + "`n")
        Save-BackupStatus "healthy" $final $destinationJson
    } else {
        Save-BackupStatus "healthy" $final
    }
    Invoke-BackupRetention $backupDirectory $retention
    Write-Host "Encrypted backup complete: $final"
    Write-Host "Test recovery regularly and keep the recovery identity separate from this PC."
} catch {
    try {
        if ($captureComplete) { Save-BackupStatus "publication_failed" $final }
        else { Save-BackupStatus "failed" }
    } catch { Write-Warning "Backup failure status could not be recorded." }
    throw
} finally {
    if ($apiPaused) {
        try { Invoke-ClearPocketCompose @("start", "api") }
        catch { Write-Warning "The API could not be resumed automatically. Use Start server from the manager." }
    }
    try { Invoke-ClearPocketCompose @("exec", "-T", "database", "rm", "-f", $databaseTemporary) }
    catch { }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
}
} finally {
    $lockStream.Dispose()
}
