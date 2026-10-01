[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\ClearPocket Server"
$versionFile = Join-Path $sourceRoot "VERSION"
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "This is not a complete versioned ClearPocket Server package."
}
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $version -eq "edge") {
    throw "The ClearPocket Server package version is invalid or not an immutable release."
}

$releaseMetadata = Join-Path $sourceRoot "RELEASE-METADATA.txt"
$contentManifest = Join-Path $sourceRoot "PACKAGE-CONTENTS-SHA256.txt"
if (Test-Path -LiteralPath $releaseMetadata -PathType Leaf) {
    if (((Get-Item -LiteralPath $releaseMetadata).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The release metadata is a linked file. Download the package again."
    }
    if (-not (Test-Path -LiteralPath $contentManifest -PathType Leaf)) {
        throw "The release package integrity manifest is missing. Download it again."
    }
    if (((Get-Item -LiteralPath $contentManifest).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The release package integrity manifest is a linked file. Download it again."
    }
    $verifiedFiles = 0
    foreach ($line in Get-Content -LiteralPath $contentManifest) {
        if ($line -notmatch '^([0-9a-f]{64})  \./(.+)$') {
            throw "The release package integrity manifest is invalid."
        }
        $expectedHash = $Matches[1]
        $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Split([IO.Path]::DirectorySeparatorChar) -contains '..') {
            throw "The release package integrity manifest contains an unsafe path."
        }
        $candidate = Join-Path $sourceRoot $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "The release package is incomplete: $relative is missing."
        }
        if (((Get-Item -LiteralPath $candidate).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The release package contains a linked program file: $relative."
        }
        $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Release package content verification failed for $relative. Download it again."
        }
        $verifiedFiles += 1
    }
    if ($verifiedFiles -eq 0) {
        throw "The release package integrity manifest is empty."
    }
    Write-Host "Release package contents verified."
}

$requiredFiles = @(
    ".env.example",
    "README.md",
    "VERSION",
    "backup-windows.ps1",
    "Caddyfile",
    "compose.yaml",
    "restore-windows.ps1",
    "start-windows.cmd",
    "start-windows.ps1",
    "tools\backup_archive.py",
    "tools\require_empty_restore.sql"
)
if (Test-Path -LiteralPath $releaseMetadata -PathType Leaf) {
    $requiredFiles += "RELEASE-METADATA.txt", "PACKAGE-CONTENTS-SHA256.txt"
}
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
        throw "The package is incomplete: $relative is missing. Download it again."
    }
}

$privateConfiguration = Join-Path $installRoot ".env"
$isUpdate = Test-Path -LiteralPath $privateConfiguration -PathType Leaf
if ((Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath $installRoot -PathType Container)) {
    throw "The ClearPocket Server install location is not a directory."
}
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

# Publish only the allowlisted replaceable bundle files. Private .env, database, attachments,
# recovery identities, and backup generations are never copied from or replaced by the installer.
foreach ($relative in $requiredFiles) {
    $source = Join-Path $sourceRoot $relative
    $destination = Join-Path $installRoot $relative
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$destination.$([Guid]::NewGuid().ToString('N')).install"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

$manager = Join-Path $installRoot "start-windows.cmd"
$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath("Desktop")
$programs = [Environment]::GetFolderPath("Programs")
foreach ($shortcutPath in @(
    (Join-Path $desktop "ClearPocket Server.lnk"),
    (Join-Path $programs "ClearPocket Server.lnk")
)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $manager
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = "Manage the private ClearPocket household server"
    $shortcut.Save()
}

if ($isUpdate) {
    Write-Host "ClearPocket Server manager $version installed. Private configuration and data were preserved."
    Write-Host "Choose 'Apply this downloaded server version' in the manager to run the backup-gated server update."
} else {
    Write-Host "ClearPocket Server manager $version installed for this Windows account."
}
Start-Process -FilePath $manager -WorkingDirectory $installRoot
