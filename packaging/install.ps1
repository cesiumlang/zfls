# Installs a zfls release on Windows: downloads the release archive for this
# computer from GitHub, checks it against the release's SHA256SUMS (and
# SHA256SUMS against its GPG signature with gpg, or the archive's build
# attestation with gh, when either is installed) and unpacks it, by default into the current directory (a portable install:
# nothing is written anywhere else, and the PATH is left alone). install.sh
# does the same on macOS and Linux.
#
#   irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1))) -Dir C:\tools -Version 0.4.0
#
# Works in Windows PowerShell 5.1 and PowerShell 7. Unlike an archive
# downloaded in a web browser, what Invoke-WebRequest downloads is not marked
# as downloaded from the internet, so SmartScreen does not question
# zfls.exe.

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
    # the release signing key (SIGNING-KEY.asc in the repository) and its fingerprint
    $keyUrl = "https://raw.githubusercontent.com/$repo/main/SIGNING-KEY.asc"
    $keyFpr = '9431367798CCD8E28BC0E589BB30DEF734E5F690'

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

    # Runs a program; its errors are its exit code, not PowerShell's
    function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $Exe @Arguments 2>$null } finally { $ErrorActionPreference = $saved }
    }

    # The same, with what the program wrote to stderr as text, for messages
    function Invoke-Captured([string]$Exe, [string[]]$Arguments) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $saved }
    }

    # C:\a\b as /c/a/b, the form an MSYS2 program (Git for Windows' gpg) reads
    function ConvertTo-MsysPath([string]$Path) {
        $p = $Path -replace '\\', '/'
        if ($p -match '^([A-Za-z]):/(.*)$') { '/' + $matches[1].ToLower() + '/' + $matches[2] } else { $p }
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

        # SHA256SUMS against its signature with the release key (gpg), else the
        # archive's build attestation (a signed-in gh); releases before 0.5.0
        # have neither
        if ($ver -match '^0\.[0-4]\.') {
            Write-Host "Note: v$ver is older than 0.5.0 and not signed; only its SHA-256 was checked"
        } elseif (Get-Command gpg -ErrorAction SilentlyContinue) {
            $asc = Join-Path $tmp 'SHA256SUMS.asc'
            try {
                Get-Https "$base/SHA256SUMS.asc" $asc
            } catch {
                throw "install.ps1: cannot download $base/SHA256SUMS.asc; the release is not verified, so it is not installed: $_"
            }
            $key = Join-Path $tmp 'key.asc'
            try { Get-Https $keyUrl $key } catch { throw "install.ps1: cannot download the release signing key ${keyUrl}: $_" }
            # a keyring of its own: the user's is not touched
            $savedHome = $env:GNUPGHOME
            $gpgHome = Join-Path $tmp 'gnupg'
            New-Item -ItemType Directory -Path $gpgHome | Out-Null
            $env:GNUPGHOME = $gpgHome
            # Git for Windows' gpg, an MSYS2 program (its home is /c/...), takes
            # a Windows path in GNUPGHOME as relative to the current directory
            if (Invoke-Quiet gpg @('--version') | Where-Object { $_ -match '^Home: /' }) {
                $env:GNUPGHOME = ConvertTo-MsysPath $gpgHome
            }
            try {
                # no gpg-agent (checking a signature needs none): MSYS2's could
                # not start in a keyring whose socket paths are over 108 bytes
                $said = Invoke-Captured gpg @('--batch', '--quiet', '--no-autostart', '--import', $key)
                if ($LASTEXITCODE -ne 0) {
                    throw "install.ps1: cannot import the release signing key with $((Get-Command gpg).Source) (GNUPGHOME $env:GNUPGHOME): $(($said | Select-Object -Last 4) -join ' | ')"
                }
                $status = Invoke-Quiet gpg @('--batch', '--no-autostart', '--status-fd', '1', '--verify', $asc, $sums)
                if ($LASTEXITCODE -ne 0) { throw "install.ps1: SHA256SUMS of v$ver does not match its signature" }
                if (-not ($status | Where-Object { $_ -match "^\[GNUPG:\] VALIDSIG .*$keyFpr" })) {
                    throw "install.ps1: SHA256SUMS of v$ver is not signed by the release key ($keyFpr)"
                }
            } finally {
                $env:GNUPGHOME = $savedHome
            }
            Write-Host "Verified the signature of SHA256SUMS (release key $keyFpr)"
        } elseif ((Get-Command gh -ErrorAction SilentlyContinue) -and (& { Invoke-Quiet gh @('auth', 'status') | Out-Null; $LASTEXITCODE -eq 0 })) {
            Invoke-Quiet gh @('attestation', 'verify', (Join-Path $tmp $archive), '--repo', $repo) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "install.ps1: $archive has no valid build attestation of $repo" }
            Write-Host "Verified the build attestation of $archive"
        } else {
            Write-Host "Note: neither gpg nor a signed-in gh is installed, so only the SHA-256 was checked, not the release's signature or attestation"
        }

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
