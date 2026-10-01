[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $EnvironmentFile
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot
$EnvironmentFile = [IO.Path]::GetFullPath($EnvironmentFile)
$emptyGuard = Join-Path $PSScriptRoot "tools\require_empty_restore.sql"
if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf)) {
    throw "Private server configuration was not found."
}
if (-not (Test-Path -LiteralPath $emptyGuard -PathType Leaf)) {
    throw "Recovery validation tools are missing. Download the complete server package again."
}

function Invoke-ClearPocketCompose([string[]] $ComposeArguments) {
    & docker compose --env-file $EnvironmentFile @ComposeArguments
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose recovery operation failed." }
}

function Write-PrivateText([string] $Path, [string] $Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Assert-EmptyRecoveryDestination([bool] $ApiIsStopped = $false) {
    $guardName = "clearpocket-empty-$([Guid]::NewGuid().ToString('N')).sql"
    $containerGuard = "/tmp/$guardName"
    try {
        Invoke-ClearPocketCompose @("cp", $emptyGuard, "database:${containerGuard}")
        Invoke-ClearPocketCompose @(
            "exec", "-T", "database", "psql", "--single-transaction", "--set", "ON_ERROR_STOP=on",
            "-U", "budget", "-d", "budget", "-f", $containerGuard
        )
    } finally {
        try { Invoke-ClearPocketCompose @("exec", "-T", "database", "rm", "-f", $containerGuard) }
        catch { }
    }
    $attachmentCheck = @("sh", "-c", 'objects="$(find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -print -quit)"; test -z "$objects"')
    if ($ApiIsStopped) {
        $arguments = @("run", "--rm", "--no-deps", "api") + $attachmentCheck
    } else {
        $arguments = @("exec", "-T", "api") + $attachmentCheck
    }
    Invoke-ClearPocketCompose $arguments
}

function Set-RecoveredAttachmentKey([string] $RecoveryLine) {
    $prefix = "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY="
    if (-not $RecoveryLine.StartsWith($prefix) -or $RecoveryLine.Length -le $prefix.Length) {
        throw "This Windows recovery requires an explicit attachment encryption key."
    }
    $settings = @(Get-Content -LiteralPath $EnvironmentFile | Where-Object { $_ -match '^BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=' })
    if ($settings.Count -ne 1) { throw "Private configuration has an ambiguous attachment key." }
    $lines = @(Get-Content -LiteralPath $EnvironmentFile | ForEach-Object {
        if ($_ -match '^BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=') { $RecoveryLine } else { $_ }
    })
    $temporary = "$EnvironmentFile.$([Guid]::NewGuid().ToString('N')).recovery"
    try {
        [IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $EnvironmentFile -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Save-RecoveryStatus([string] $Archive) {
    $status = [ordered]@{
        state = "verified"
        verified_at = [DateTimeOffset]::UtcNow.ToString("o")
        source_provider = "shared_server_postgresql"
        source_archive_sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
        database_integrity = "ok"
        foreign_keys = "ok"
    }
    $statusFile = Join-Path $env:TEMP "clearpocket-recovery-status-$([Guid]::NewGuid().ToString('N')).json"
    try {
        Write-PrivateText $statusFile (($status | ConvertTo-Json) + "`n")
        Invoke-ClearPocketCompose @(
            "run", "--rm", "--no-deps", "--user", "root",
            "--volume", "${statusFile}:/input/recovery-status.json:ro",
            "api", "sh", "-c",
            "install -m 600 -o budget -g budget /input/recovery-status.json " +
            "/var/lib/budget-app/operations/recovery-status.json"
        )
    } finally {
        Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Restore an encrypted ClearPocket Server backup"
Write-Host "The configured database and attachment folder must be empty. Existing data is never overwritten."
$archiveInput = Read-Host "Full path to the encrypted .tar.gz.age backup"
if ([string]::IsNullOrWhiteSpace($archiveInput)) { throw "No encrypted backup was selected." }
$archive = Get-Item -LiteralPath ([IO.Path]::GetFullPath($archiveInput)) -Force
if ($archive.PSIsContainer -or ($archive.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "The recovery archive must be a regular, non-linked file."
}
$identityInput = Read-Host "Full path to the recovery identity (leave blank for a passphrase backup)"
$identity = $null
if (-not [string]::IsNullOrWhiteSpace($identityInput)) {
    $identity = Get-Item -LiteralPath ([IO.Path]::GetFullPath($identityInput)) -Force
    if ($identity.PSIsContainer -or ($identity.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The recovery identity must be a regular, non-linked file."
    }
}
$confirmation = Read-Host "Type RESTORE to verify this backup and initialize the empty server"
if ($confirmation -cne "RESTORE") {
    Write-Host "Recovery cancelled. No server data or configuration was changed."
    exit 0
}

$staging = Join-Path $env:TEMP "clearpocket-restore-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging | Out-Null
$apiStopped = $false
$restoreCommitted = $false
$guardContainer = "/tmp/clearpocket-guard-$([Guid]::NewGuid().ToString('N')).sql"
$databaseContainer = "/tmp/clearpocket-restore-$([Guid]::NewGuid().ToString('N')).sql"

try {
    Invoke-ClearPocketCompose @("up", "-d", "database", "api")
    Assert-EmptyRecoveryDestination

    $arguments = @(
        "run", "--rm", "--no-deps", "--user", "root",
        "--volume", "$($archive.FullName):/input/archive.age:ro",
        "--volume", "${staging}:/restore",
        "--entrypoint", "sh"
    )
    $decrypt = "age --decrypt /input/archive.age > /restore/archive.tar.gz"
    if ($null -ne $identity) {
        $arguments += @("--volume", "$($identity.FullName):/input/identity.txt:ro")
        $decrypt = "age --decrypt --identity /input/identity.txt /input/archive.age > /restore/archive.tar.gz"
    }
    $arguments += @(
        "api", "-c", "$decrypt && python scripts/backup_archive.py " +
        "extract-verified /restore/archive.tar.gz /restore/verified && rm -f /restore/archive.tar.gz"
    )
    Invoke-ClearPocketCompose $arguments

    $verified = Join-Path $staging "verified"
    $recoveryFile = Join-Path $verified "attachment-key-recovery.env"
    if (-not (Test-Path -LiteralPath $recoveryFile -PathType Leaf)) {
        throw "Verified recovery payload has no attachment recovery material."
    }
    $recoveryLine = (Get-Content -LiteralPath $recoveryFile -Raw).Trim()
    if ($recoveryLine -notmatch '^BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=\S+$') {
        throw "Verified attachment recovery material is invalid."
    }

    Invoke-ClearPocketCompose @("stop", "api")
    $apiStopped = $true
    Assert-EmptyRecoveryDestination $true
    Set-RecoveredAttachmentKey $recoveryLine
    Remove-Variable recoveryLine

    Invoke-ClearPocketCompose @(
        "run", "--rm", "--no-deps", "--volume", "${verified}:/restore:ro",
        "api", "sh", "-c",
        'objects="$(find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -print -quit)"; ' +
        'test -z "$objects" && cp -R /restore/attachments/. /var/lib/budget-app/attachments/ && ' +
        'chmod -R u=rwX,go= /var/lib/budget-app/attachments'
    )
    Invoke-ClearPocketCompose @("cp", $emptyGuard, "database:${guardContainer}")
    Invoke-ClearPocketCompose @("cp", (Join-Path $verified "database.sql"), "database:${databaseContainer}")
    Invoke-ClearPocketCompose @(
        "exec", "-T", "database", "psql", "--single-transaction", "--set", "ON_ERROR_STOP=on",
        "-U", "budget", "-d", "budget", "-f", $guardContainer, "-f", $databaseContainer
    )
    $restoreCommitted = $true
    Save-RecoveryStatus $archive.FullName
    Invoke-ClearPocketCompose @("up", "-d", "--force-recreate", "api")
    $portSettings = @(Get-Content -LiteralPath $EnvironmentFile | Where-Object { $_ -match '^CLEARPOCKET_PORT=' })
    $serverPort = 0
    if ($portSettings.Count -ne 1 -or
        -not [int]::TryParse($portSettings[0].Split('=', 2)[1], [ref] $serverPort) -or
        $serverPort -lt 1 -or $serverPort -gt 65535) {
        throw "Private configuration has an invalid server port."
    }
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$serverPort/api/v1/health" -TimeoutSec 3
            if ($response.StatusCode -eq 200) { $apiStopped = $false; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if ($apiStopped) { throw "Recovered data committed, but the API did not become healthy." }
    Write-Host "Encrypted backup restored and verified. Preserve the source backup and recovery identity until a new backup succeeds."
} catch {
    if ($restoreCommitted) {
        Write-Warning "Recovery data committed, but activation failed. The API remains stopped for inspection."
    } else {
        Write-Warning "Recovery failed before commit. The source archive was not changed."
    }
    try { Invoke-ClearPocketCompose @("stop", "api") } catch { }
    throw
} finally {
    try { Invoke-ClearPocketCompose @("exec", "-T", "database", "rm", "-f", $guardContainer, $databaseContainer) }
    catch { }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
