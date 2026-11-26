# Installs a zfls release on Windows: downloads the release archive for this
# computer from GitHub, checks it against the release's SHA256SUMS and
# unpacks it, by default into the current directory (a portable install:
# nothing is written anywhere else, and the PATH is left alone). install.sh
# does the same on macOS and Linux.
#
#   irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1))) -Dir C:\tools -Version 0.4.0
#
# Works in Windows PowerShell 5.1 and PowerShell 7. Unlike an archive
# downloaded in a web browser, what Invoke-WebRequest downloads is not marked
# as downloaded from the internet, so SmartScreen does not question the
# unsigned zfls.exe.

param(
    # Where to unpack the release, as DIR\zfls-v<version>-<target>\zfls.exe
    [string]$Dir = '.',
    # The release to install, such as 0.4.0 (default: the latest)
    [string]$Version = ''
)

# In a script block of its own, so that the preferences set here do not stay
# in the session that ran `irm ... | iex`. Errors are thrown rather than
# exiting, which would close that session.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is slow with it
    $repo = 'cesiumlang/zfls'

    # TLS 1.2 (Windows PowerShell 5.1 may not offer it by default), and
    # nothing older
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Downloads URL to FILE, over https only: a redirect to another scheme is
    # an error
    function Get-Https([string]$Url, [string]$OutFile) {
        if (-not $Url.StartsWith('https://')) { throw "install.ps1: not an https URL: $Url" }
        $r = Invoke-WebRequest -UseBasicParsing $Url -OutFile $OutFile -PassThru
        $final = $null
        if ($r.BaseResponse.PSObject.Properties['ResponseUri']) { $final = $r.BaseResponse.ResponseUri }
        elseif ($r.BaseResponse.PSObject.Properties['RequestMessage']) { $final = $r.BaseResponse.RequestMessage.RequestUri }
        if ($final -and $final.Scheme -ne 'https') {
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
            throw "install.ps1: $Url was redirected to $final, which is not https"
        }
    }

    # The architecture of Windows itself, also when this PowerShell runs
    # emulated (x64 on Arm)
    $arch = $null
    try { $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    if (-not $arch) {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    switch -Regex ($arch) {
        '^(X64|AMD64)$' { $arch = 'x86_64'; break }
        '^(Arm64|ARM64)$' { $arch = 'aarch64'; break }
        default { throw "install.ps1: there is no zfls release for $arch; build it from source (see https://github.com/$repo#building)" }
    }

    $ver = $Version
    if (-not $ver) {
        # Read from the names in the latest release's SHA256SUMS, which
        # releases/latest/download/ serves without GitHub's API and its rate
        # limit (60 requests an hour from one address, which CI runners share)
        $latest = [IO.Path]::GetTempFileName()
        try {
            Get-Https "https://github.com/$repo/releases/latest/download/SHA256SUMS" $latest
            foreach ($line in Get-Content $latest) {
                if ($line -match "zfls-v(.+)-$arch-windows\.zip$") { $ver = $Matches[1]; break }
            }
        } catch {
            throw "install.ps1: cannot find the latest release of ${repo}: $_"
        } finally {
            Remove-Item -Force $latest -ErrorAction SilentlyContinue
        }
        if (-not $ver) { throw "install.ps1: the latest release of $repo has no archive for $arch-windows" }
    }
    $ver = $ver -replace '^v', ''
    $name = "zfls-v$ver-$arch-windows"
    $archive = "$name.zip"
    $base = "https://github.com/$repo/releases/download/v$ver"

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("zfls-install-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "Downloading $archive"
        try {
            Get-Https "$base/$archive" (Join-Path $tmp $archive)
        } catch {
            throw "install.ps1: cannot download $base/$archive (is $ver a release of zfls?): $_"
        }

        # an archive that cannot be verified is not unpacked
        $sums = Join-Path $tmp 'SHA256SUMS'
        try {
            Get-Https "$base/SHA256SUMS" $sums
        } catch {
            throw "install.ps1: cannot download $base/SHA256SUMS; the archive is not verified, so it is not installed: $_"
        }
        $expected = $null
        foreach ($line in Get-Content $sums) {
            $fields = $line.Trim() -split '\s+', 2
            if ($fields.Count -eq 2 -and $fields[1].TrimStart('*') -eq $archive) { $expected = $fields[0] }
        }
        if (-not $expected) { throw "install.ps1: SHA256SUMS of v$ver does not list $archive" }
        $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $archive)).Hash
        if ($actual -ne $expected) { throw "install.ps1: $archive does not match its SHA-256 in SHA256SUMS" }

        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Expand-Archive -Path (Join-Path $tmp $archive) -DestinationPath $Dir -Force
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    $installDir = (Resolve-Path (Join-Path $Dir $name)).ProviderPath
    $exe = Join-Path $installDir 'zfls.exe'
    & $exe --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "install.ps1: $exe was unpacked but does not run" }

    Write-Host "Installed zfls $ver in $installDir"
    Write-Host "To run it as zfls, add that directory to your PATH, for example:"
    Write-Host "  `$env:Path = `"$installDir;`$env:Path`"            # this session"
    Write-Host "  [Environment]::SetEnvironmentVariable('Path', `"$installDir;`" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')  # from now on"
}
