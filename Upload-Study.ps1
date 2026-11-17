param(
    [string]$RepoRoot = $PSScriptRoot,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Set-Location -LiteralPath $RepoRoot
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Git {
    param([string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "Git failed: git $($GitArgs -join ' ')" }
}

function Get-StreamHash($Stream) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Stream)) }
    finally { $sha.Dispose() }
}

function Get-FolderManifest($Directory) {
    $result = @{}
    $files = Get-ChildItem -LiteralPath $Directory.FullName -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\(\.git|\.venv|__pycache__)(\\|$)' }
    foreach ($file in $files) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked file: $($file.FullName)" }
        $name = $file.FullName.Substring($RepoRoot.Length + 1).Replace('\', '/')
        $result[$name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return ,$result
}

function Get-ZipManifest($Path) {
    $result = @{}
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $stream = $entry.Open()
            try { $result[$entry.FullName] = (Get-StreamHash $stream).Replace('-', '') }
            finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return ,$result
}

function Test-SameManifest($Left, $Right) {
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($key in $Left.Keys) {
        if (-not $Right.ContainsKey($key) -or $Left[$key] -ne $Right[$key]) { return $false }
    }
    return $true
}

function Add-IgnoreLine($Line) {
    $path = Join-Path $RepoRoot '.gitignore'
    $lines = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllLines($path) } else { @() }
    if ($lines -notcontains $Line) { [IO.File]::WriteAllLines($path, @($lines) + $Line, $utf8) }
}

function Replace-Archive($Source, $Destination) {
    if (Test-Path -LiteralPath $Destination) {
        $backup = $Source + '.previous'
        [IO.File]::Replace($Source, $Destination, $backup)
        Remove-Item -LiteralPath $backup
    } else { [IO.File]::Move($Source, $Destination) }
}

$lock = $null
$temporary = $null
try {
    Invoke-Git -GitArgs @('rev-parse', '--show-toplevel') | Out-Null
    $gitDir = (& git rev-parse --absolute-git-dir).Trim()
    $lockPath = Join-Path $gitDir 'study-upload.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $staged = & git diff --cached --name-only
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check the Git index.' }
    if ($staged) { throw 'There are staged changes. Commit or unstage them before running this script.' }
    $branch = (& git branch --show-current).Trim()
    if ($branch -ne 'main') { throw 'Switch to main before uploading.' }

    $managed = @()
    foreach ($directory in (Get-ChildItem -LiteralPath $RepoRoot -Directory | Where-Object { -not $_.Name.StartsWith('.') })) {
        $zipName = $directory.Name + '.zip'
        & git check-ignore --quiet -- $zipName
        if ($LASTEXITCODE -eq 0) { Write-Host "Ignored: $($directory.Name)"; continue }
        if ($LASTEXITCODE -ne 1) { throw 'Cannot read ignore rules.' }
        $zipPath = Join-Path $RepoRoot $zipName
        $before = Get-FolderManifest $directory
        if ((Test-Path -LiteralPath $zipPath) -and (Test-SameManifest $before (Get-ZipManifest $zipPath))) {
            Write-Host "Unchanged: $zipName"
        } else {
            Write-Host "Compressing: $zipName"
            $temporary = Join-Path $gitDir ('study-' + [guid]::NewGuid().ToString('N') + '.zip')
            $zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in ($before.Keys | Sort-Object)) {
                    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $RepoRoot $name), $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
                }
                if ($before.Count -eq 0) { $zip.CreateEntry($directory.Name + '/') | Out-Null }
            } finally { $zip.Dispose() }
            if (-not (Test-SameManifest $before (Get-ZipManifest $temporary)) -or
                -not (Test-SameManifest $before (Get-FolderManifest $directory))) {
                throw "Files changed while compressing $zipName. Wait for file writes to finish and run again."
            }
            Replace-Archive $temporary $zipPath
            $temporary = $null
        }
        Add-IgnoreLine ('/' + $directory.Name + '/')
        $managed += $zipName
    }

    # Preserve the existing circuit archive and update only matching root PDFs.
    $circuitName = [string]::Concat([char]0x7535, [char]0x8def)
    $circuitZip = Join-Path $RepoRoot ($circuitName + '.zip')
    if (Test-Path -LiteralPath $circuitZip) {
        $manifest = Get-ZipManifest $circuitZip
        $pdfs = @(Get-ChildItem -LiteralPath $RepoRoot -File -Filter ($circuitName + '*.pdf'))
        $updates = @($pdfs | Where-Object { $manifest[$circuitName + '/' + $_.Name] -ne (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        if ($updates.Count -gt 0) {
            Write-Host "Updating: $circuitName.zip"
            $temporary = Join-Path $gitDir ('study-' + [guid]::NewGuid().ToString('N') + '.zip')
            Copy-Item -LiteralPath $circuitZip -Destination $temporary
            $expected = @{} + $manifest
            $zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Update)
            try {
                foreach ($pdf in $updates) {
                    $name = $circuitName + '/' + $pdf.Name
                    $expected[$name] = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash
                    $old = $zip.GetEntry($name)
                    if ($old) { $old.Delete() }
                    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $pdf.FullName, $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
                }
            } finally { $zip.Dispose() }
            if (-not (Test-SameManifest $expected (Get-ZipManifest $temporary))) { throw 'Circuit archive validation failed.' }
            foreach ($pdf in $updates) {
                if ($expected[$circuitName + '/' + $pdf.Name] -ne (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash) { throw 'Circuit PDF changed during compression.' }
            }
            Replace-Archive $temporary $circuitZip
            $temporary = $null
        }
    }

    # Include existing root ZIPs, but always honor .gitignore.
    $archives = @(Get-ChildItem -LiteralPath $RepoRoot -File -Filter '*.zip' | Where-Object {
        & git check-ignore --quiet -- $_.Name
        if ($LASTEXITCODE -gt 1) { throw 'Cannot read ignore rules.' }
        $LASTEXITCODE -eq 1
    })
    foreach ($archive in $archives) {
        if ($archive.Length -gt 100MB) {
            Invoke-Git -GitArgs @('lfs', 'install', '--local') | Out-Host
            Invoke-Git -GitArgs @('lfs', 'track', '--', $archive.Name) | Out-Host
        }
    }
    foreach ($archive in $archives) { Invoke-Git -GitArgs @('add', '--', $archive.Name) }
    foreach ($rule in @('.gitignore', '.gitattributes')) {
        if (Test-Path -LiteralPath $rule) { Invoke-Git -GitArgs @('add', '--', $rule) }
    }
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 1) { Invoke-Git -GitArgs @('commit', '-m', ('Update study archives ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) }
    elseif ($LASTEXITCODE -ne 0) { throw 'Cannot check staged changes.' }
    else { Write-Host 'No archive changes to commit.' }
    if (-not $NoPush) { Invoke-Git -GitArgs @('push', '--progress', 'origin', 'main') }
    Write-Host 'Done.' -ForegroundColor Green
} catch {
    Write-Host ("FAILED: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Local files and commits are retained. Fix the error and run again.'
    exit 1
} finally {
    if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary }
    if ($lock) { $lock.Dispose() }
}
