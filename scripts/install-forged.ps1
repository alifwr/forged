# Install a complete Forged package without moving existing Codex session data.
& {
    $ErrorActionPreference = 'Stop'

    if ($env:OS -ne 'Windows_NT') {
        throw 'This installer requires Windows. Use install-forged.sh on Linux or macOS.'
    }
    foreach ($tool in @('git', 'cargo', 'rustc')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Forged needs $tool installed before it can be built."
        }
    }

    $pythonPrefix = @()
    $python = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($python) {
        $pythonPrefix = @('-3')
    } else {
        $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $python) {
        throw 'Forged needs Python 3.10 or later installed before it can be built.'
    }
    & $python.Source @pythonPrefix -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
    if ($LASTEXITCODE -ne 0) {
        throw 'Forged needs Python 3.10 or later.'
    }

    $rustInfo = & rustc -vV
    if ($LASTEXITCODE -ne 0) { throw 'Could not query the Rust toolchain.' }
    $hostLine = $rustInfo | Where-Object { $_ -like 'host: *' } | Select-Object -First 1
    if (-not $hostLine) { throw 'Could not determine the Rust host target.' }
    $target = $hostLine.Substring(6).Trim()
    if ($target -notin @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
        throw "Unsupported Rust target $target. Install the Windows MSVC Rust toolchain."
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
        if ($metadata.variant -ne 'forged' -or $metadata.entrypoint -ne 'bin/forged.exe') {
            throw "Refusing to replace an unrelated package at $path"
        }
        return $true
    }
    [void](Test-ManagedPackage $current)

    $sourceTemp = $null
    $releaseDir = $null
    $oldRepoRoot = $env:CODEX_REPO_ROOT
    $oldBuildJobs = $env:CARGO_BUILD_JOBS
    try {
        if ($env:FORGED_SOURCE_DIR) {
            $sourceDir = (Resolve-Path -LiteralPath $env:FORGED_SOURCE_DIR).ProviderPath
        } else {
            $sourceTemp = Join-Path ([IO.Path]::GetTempPath()) ('forged-source-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $sourceTemp | Out-Null
            $sourceDir = Join-Path $sourceTemp 'repo'
            Write-Host 'Cloning Forged source...'
            & git clone --depth 1 --branch main https://github.com/alifwr/forged.git $sourceDir
            if ($LASTEXITCODE -ne 0) { throw 'Could not clone the Forged repository.' }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'codex-rs\cli\src\bin\forged.rs') -PathType Leaf)) {
            throw 'The source does not contain the forged binary target. Update the repository first.'
        }

        New-Item -ItemType Directory -Path $releases -Force | Out-Null
        $releaseDir = Join-Path $releases ('build-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $releaseDir | Out-Null
        $package = Join-Path $releaseDir 'package'
        $env:CODEX_REPO_ROOT = $sourceDir
        if (-not $env:CARGO_BUILD_JOBS) { $env:CARGO_BUILD_JOBS = '1' }
        Write-Host "Building Forged and its runtime helpers for $target with $($env:CARGO_BUILD_JOBS) Cargo job(s). This can take a while..."
        & $python.Source @pythonPrefix (Join-Path $sourceDir 'scripts\build_codex_package.py') `
            --variant forged --target $target --cargo-profile release --package-dir $package
        if ($LASTEXITCODE -ne 0) { throw 'The Forged package build failed.' }
        if (-not (Test-Path -LiteralPath (Join-Path $package 'bin\forged.exe') -PathType Leaf)) {
            throw 'The package did not produce forged.exe.'
        }

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
        [Environment]::SetEnvironmentVariable('CODEX_REPO_ROOT', $oldRepoRoot, 'Process')
        [Environment]::SetEnvironmentVariable('CARGO_BUILD_JOBS', $oldBuildJobs, 'Process')
        if ($sourceTemp -and (Test-Path -LiteralPath $sourceTemp)) {
            Remove-Item -LiteralPath $sourceTemp -Recurse -Force -ErrorAction Continue
        }
        if ($releaseDir -and (Test-Path -LiteralPath $releaseDir)) {
            Remove-Item -LiteralPath $releaseDir -Recurse -Force -ErrorAction Continue
        }
    }
}
