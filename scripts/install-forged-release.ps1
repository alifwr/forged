# Install a verified prebuilt Forged package without moving existing Codex session data.
& {
    $ErrorActionPreference = 'Stop'

    if ($env:OS -ne 'Windows_NT') {
        throw 'This installer requires Windows. Use install-forged.sh on Linux or macOS.'
    }
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') {
        throw "No prebuilt Forged package is available for Windows architecture $architecture."
    }

    $dataDir = if ($env:FORGED_DATA_DIR) {
        [IO.Path]::GetFullPath($env:FORGED_DATA_DIR)
    } else {
        Join-Path $env:LOCALAPPDATA 'Programs\Forged'
    }
    $current = Join-Path $dataDir 'current'
    $releases = Join-Path $dataDir 'releases'
    $binDir = Join-Path $current 'bin'
    function Test-ManagedPackage([string]$path) {
        $existing = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not $existing) { return $false }
        $manifest = Join-Path $path 'codex-package.json'
        if (-not $existing.PSIsContainer -or
            ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "Refusing to replace an unmanaged installation at $path"
        }
        try { $metadata = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json }
        catch { throw "Refusing to replace an invalid package at $path" }
        if ($metadata.variant -ne 'forged' -or $metadata.entrypoint -notin @('bin/forged.exe', 'bin/codex.exe')) {
            throw "Refusing to replace an unrelated package at $path"
        }
        return $true
    }
    [void](Test-ManagedPackage $current)

    $releaseDir = $null
    try {
        New-Item -ItemType Directory -Path $releases -Force | Out-Null
        $releaseDir = Join-Path $releases ('download-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $releaseDir | Out-Null
        $package = Join-Path $releaseDir 'package'
        $archive = Join-Path $releaseDir 'forged-windows-x86_64.zip'
        $checksum = Join-Path $releaseDir 'forged-windows-x86_64.zip.sha256'
        $baseUrl = 'https://github.com/alifwr/forged/releases/latest/download'
        Write-Host 'Downloading the latest Forged release...'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/forged-windows-x86_64.zip.sha256" -OutFile $checksum
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/forged-windows-x86_64.zip" -OutFile $archive
        } catch {
            throw "Could not download the latest Forged Windows release. Check https://github.com/alifwr/forged/releases. $($_.Exception.Message)"
        }
        $checksumText = (Get-Content -LiteralPath $checksum -Raw).Trim()
        if ($checksumText -notmatch '^([0-9a-fA-F]{64})(?:\s+\*?forged-windows-x86_64\.zip)?$') {
            throw 'The release checksum file is invalid.'
        }
        $expectedHash = $Matches[1]
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expectedHash) {
            throw 'The Forged package checksum does not match. Nothing was installed.'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -match '(^[/\\]|^[a-zA-Z]:|(^|[/\\])\.\.([/\\]|$))' -or
                    (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                    throw 'The Forged package contains an unsafe archive entry.'
                }
            }
        } finally { $zip.Dispose() }
        Expand-Archive -LiteralPath $archive -DestinationPath $package
        foreach ($required in @('bin\forged.exe', 'bin\codex-code-mode-host.exe', 'bin\codex-exec-server.exe',
                'codex-path\rg.exe', 'codex-resources\codex-command-runner.exe',
                'codex-resources\codex-windows-sandbox-setup.exe', 'codex-package.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $package $required) -PathType Leaf)) {
                throw "The Forged package is missing $required. Nothing was installed."
            }
        }
        $packageMetadata = Get-Content -LiteralPath (Join-Path $package 'codex-package.json') -Raw | ConvertFrom-Json
        if ($packageMetadata.variant -ne 'forged' -or $packageMetadata.entrypoint -ne 'bin/forged.exe' -or
            $packageMetadata.target -ne 'x86_64-pc-windows-msvc') {
            throw 'The downloaded package metadata does not describe Forged for Windows x64.'
        }

        # The daemon stages a canonical codex.exe and treats version 0.0.0 as a local, pinned build.
        Copy-Item -LiteralPath (Join-Path $package 'bin\forged.exe') -Destination (Join-Path $package 'bin\codex.exe') -Force
        $packageMetadata | Add-Member -NotePropertyName forgedReleaseVersion -NotePropertyValue $packageMetadata.version -Force
        $packageMetadata.entrypoint = 'bin/codex.exe'
        $packageMetadata.version = '0.0.0'
        $metadataJson = $packageMetadata | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText((Join-Path $package 'codex-package.json'), $metadataJson, (New-Object Text.UTF8Encoding $false))

        $backup = $null
        if (Test-ManagedPackage $current) {
            $backup = Join-Path $releases ('previous-' + [guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $current -Destination $backup
        }
        try {
            Move-Item -LiteralPath $package -Destination $current
        } catch {
            if ($backup) {
                try { Move-Item -LiteralPath $backup -Destination $current }
                catch { Write-Warning "Could not restore the previous package; it remains at $backup" }
            }
            throw
        }
        if ($backup) {
            try { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Could not remove the previous package at $backup" }
        }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @($userPath -split ';' | Where-Object { $_ })
        if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') })) {
            try {
                $updatedPath = (@($entries) + @($binDir)) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
            } catch {
                Write-Warning "Could not update your user PATH. Add $binDir manually."
            }
        }
        if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') })) {
            $env:Path = "$binDir;$env:Path"
        }
        Write-Host "Installed Forged at $binDir\forged.exe"
        Write-Host 'Run: forged'
        Write-Host 'Existing sessions remain in ~/.codex (or CODEX_HOME).'
    } finally {
        if ($releaseDir -and (Test-Path -LiteralPath $releaseDir)) {
            Remove-Item -LiteralPath $releaseDir -Recurse -Force -ErrorAction Continue
        }
    }
}
