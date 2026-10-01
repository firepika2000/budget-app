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
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is installed but is not running." }

$environmentFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path -LiteralPath $environmentFile)) {
    Write-Host "ClearPocket Server first-time setup"
    Write-Host "The iPhone app requires HTTPS for remote servers. This preview starts a local server; do not expose port 8080 to the Internet."
    $hostName = Read-Host "This PC's protected-LAN hostname or IP address"
    Assert-SafeValue $hostName "Hostname"

    $defaultRoot = Join-Path $env:ProgramData "ClearPocket Server"
    $storageRoot = Read-Host "Data folder [$defaultRoot]"
    if ([string]::IsNullOrWhiteSpace($storageRoot)) { $storageRoot = $defaultRoot }
    $storageRoot = [IO.Path]::GetFullPath($storageRoot)
    Assert-SafeValue $storageRoot "Data folder"
    $database = Join-Path $storageRoot "database"
    $attachments = Join-Path $storageRoot "attachments"
    New-Item -ItemType Directory -Force -Path $database, $attachments | Out-Null
    $databaseDocker = $database.Replace('\', '/')
    $attachmentsDocker = $attachments.Replace('\', '/')

    $lines = @(
        "CLEARPOCKET_SERVER_IMAGE=ghcr.io/firepika2000/budget-server",
        "CLEARPOCKET_SERVER_VERSION=$serverVersion",
        "CLEARPOCKET_BIND_ADDRESS=0.0.0.0",
        "CLEARPOCKET_PORT=8080",
        "CLEARPOCKET_DATABASE_STORAGE=$databaseDocker",
        "CLEARPOCKET_ATTACHMENTS_STORAGE=$attachmentsDocker",
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

docker compose --env-file .env up -d
if ($LASTEXITCODE -ne 0) { throw "ClearPocket Server did not start." }
Write-Host "ClearPocket Server started. Opening local household setup..."
Start-Process "http://127.0.0.1:8080/admin"
