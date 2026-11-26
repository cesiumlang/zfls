# Tests the failure paths of packaging/install.ps1 against a fake release:
# Invoke-WebRequest is replaced by a function that serves files from a
# directory, so nothing is downloaded, and gpg by one that answers as
# $script:gpgMode says. Each must stop with the message named, before the
# archive is unpacked.
# Run: pwsh -File tests/install_ps1_test.ps1 (or powershell -File ...)
$ErrorActionPreference = 'Stop'
$script = if ($env:INSTALL_PS1) { $env:INSTALL_PS1 } else { Join-Path $PSScriptRoot '..\packaging\install.ps1' }
$work = Join-Path ([IO.Path]::GetTempPath()) ("zfls-install-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path "$work\serve" | Out-Null
$script:serve = "$work\serve"
$script:redirectTo = $null
$script:failed = 0
$script:requested = New-Object System.Collections.Generic.List[string]
$script:gpgMode = 'good'
$fpr = '9431367798CCD8E28BC0E589BB30DEF734E5F690'

function gpg {
    if ($args -contains '--import') { $global:LASTEXITCODE = 0; return }
    switch ($script:gpgMode) {
        'good' { $global:LASTEXITCODE = 0; "[GNUPG:] VALIDSIG $fpr 2026-11-25 0 4 0 22 8 00 $fpr" }
        'other' { $global:LASTEXITCODE = 0; '[GNUPG:] VALIDSIG 0000000000000000000000000000000000000000 2026-11-25' }
        default { $global:LASTEXITCODE = 1; '[GNUPG:] BADSIG x' }
    }
}

function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [Parameter(Position = 0)][string]$Uri, [string]$OutFile, [switch]$PassThru)
    $script:requested.Add($Uri)
    $f = Join-Path $script:serve ($Uri.Substring($Uri.LastIndexOf('/') + 1))
    if (-not (Test-Path $f)) { throw "404 $Uri" }
    Copy-Item $f $OutFile
    $final = if ($script:redirectTo) { [uri]$script:redirectTo } else { [uri]$Uri }
    [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = $final } }
}

# the archive's name depends on the computer's architecture
$arch = if ([string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -match 'Arm64') { 'aarch64' } else { 'x86_64' }
$archive = "zfls-v9.9.9-$arch-windows.zip"
[IO.File]::WriteAllText("$work\serve\$archive", 'not really a zip')
$good = (Get-FileHash -Algorithm SHA256 "$work\serve\$archive").Hash.ToLower()
[IO.File]::WriteAllText("$work\serve\SIGNING-KEY.asc", 'key')

function Check([string]$title, [string]$pattern, [string]$sums, [string]$redirect = $null) {
    Remove-Item -Force "$work\serve\SHA256SUMS" -ErrorAction SilentlyContinue
    if ($sums) { [IO.File]::WriteAllText("$work\serve\SHA256SUMS", $sums) }
    $script:redirectTo = $redirect
    $dest = "$work\dest"
    Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
    $message = $null
    try {
        & ([scriptblock]::Create((Get-Content -Raw $script))) -Dir $dest -Version 9.9.9
    } catch {
        $message = "$_"
    }
    if (-not $message) {
        Write-Host "FAIL ${title}: install.ps1 did not stop"
        $script:failed++
    } elseif ($message -notmatch $pattern) {
        Write-Host "FAIL ${title}: stopped with '$message', not '$pattern'"
        $script:failed++
    } elseif (Test-Path "$dest\zfls-v9.9.9-$arch-windows") {
        Write-Host "FAIL ${title}: unpacked the archive"
        $script:failed++
    } else {
        Write-Host "ok   ${title}"
    }
}

try {
    Check 'no SHA256SUMS' 'not verified, so it is not installed' $null
    Check 'a checksum that does not match' 'does not match its SHA-256' ("{0}  {1}`n" -f ('0' * 64), $archive)
    Check 'an archive that is not listed' 'does not list' ("{0}  other.zip`n" -f $good)
    Check 'a redirect to http' 'not https' ("{0}  {1}`n" -f $good, $archive) 'http://example.com/x'
    Check 'a release of 0.5.0 on without SHA256SUMS.asc' 'SHA256SUMS.asc; the release is not verified' ("{0}  {1}`n" -f $good, $archive)
    [IO.File]::WriteAllText("$work\serve\SHA256SUMS.asc", 'sig')
    $script:gpgMode = 'bad'
    Check 'a signature that does not verify' 'does not match its signature' ("{0}  {1}`n" -f $good, $archive)
    $script:gpgMode = 'other'
    Check 'a signature by another key' 'not signed by the release key' ("{0}  {1}`n" -f $good, $archive)
    $script:gpgMode = 'good'
    if ($script:requested | Where-Object { -not $_.StartsWith('https://') }) {
        Write-Host 'FAIL a request was not for an https URL'
        $script:failed++
    } else {
        Write-Host 'ok   every request is for an https URL'
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { exit 1 }
