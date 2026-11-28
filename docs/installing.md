# Installing

Each [release](https://github.com/cesiumlang/zfls/releases) publishes the `zfls` executable for Linux, macOS and Windows, each on x86_64 and ARM64, as `zfls-v<version>-<target>.tar.gz` (`.zip` on Windows), with `SHA256SUMS`. The executable needs nothing else: it can be run from wherever it is unpacked.

The installation scripts in `packaging` download the archive for the computer they run on, check it against `SHA256SUMS` (they stop, and unpack nothing, when that is missing or does not match) and unpack it, by default into the current directory, as `zfls-v<version>-<target>/zfls` (`zfls.exe` on Windows). They change nothing else, the `PATH` included. On macOS and Linux, or in Git Bash, MSYS2 or Cygwin on Windows:

```sh
curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh
```

`--dir DIR` unpacks it into DIR instead, and `--version VERSION` installs that release rather than the latest:

```sh
curl -fsSL https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.sh | sh -s -- --dir ~/tools --version 0.4.0
```

In PowerShell on Windows (Windows PowerShell 5.1 or PowerShell 7):

```powershell
irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1 | iex
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cesiumlang/zfls/main/packaging/install.ps1))) -Dir C:\tools -Version 0.4.0
```

On macOS there is also an installer package, `zfls-v<version>-macos.pkg`, one for Apple Silicon and Intel: open it, and it installs `zfls` into `/usr/local/bin` and the license into `/usr/local/share/doc/zfls`. To remove it, delete those (`sudo rm /usr/local/bin/zfls` and `sudo rm -r /usr/local/share/doc/zfls`) and forget the package (`sudo pkgutil --forget com.github.cesiumlang.zfls`).

Releases from 0.5.0 on are signed: `zfls.exe` with an Authenticode signature, and `zfls` on macOS, in the archives and the installer package, with a Developer ID and notarized by Apple (earlier releases are not signed). A browser still marks what it downloads as coming from the internet. On macOS, double-clicking the unpacked `zfls` in Finder then shows *Apple could not verify "zfls" is free of malware*, as it does for any command-line program marked that way, Apple's own included: run it from a terminal instead, which works, or use the installer package. Unpack the archive with `tar -xzf` in a terminal (Finder's Archive Utility passes the mark on to what it unpacks), or use the installation scripts, whose downloads are not marked. If a mark is on `zfls` already, remove it with `xattr -d com.apple.quarantine zfls`. On Windows, SmartScreen may still ask about a program it has not seen before: unblock the zip before unpacking it if it does (`Unblock-File`, or "Unblock" in its Properties).

A release can be verified: `SHA256SUMS` has a detached GPG signature, `SHA256SUMS.asc`, made with the release signing key in [`SIGNING-KEY.asc`](https://github.com/cesiumlang/zfls/blob/main/SIGNING-KEY.asc) (fingerprint `9431 3677 98CC D8E2 8BC0 E589 BB30 DEF7 34E5 F690`). Import the key, check the signature, then the archive: `gpg --import SIGNING-KEY.asc`, `gpg --verify SHA256SUMS.asc SHA256SUMS`, `sha256sum -c --ignore-missing SHA256SUMS`. Every release file also has a GitHub build attestation: `gh attestation verify zfls-v<version>-<target>.tar.gz --repo cesiumlang/zfls`. The install scripts do this themselves: with `gpg` installed they check `SHA256SUMS.asc` against the release key (fetched from this repository and imported into a keyring of their own; its fingerprint is in the scripts), else with a signed-in `gh` the archive's attestation, and they stop when the check fails or, from 0.5.0 on, when the signature is missing; with neither tool they say that only the SHA-256 was checked. Releases before 0.5.0 are not signed.

The VS Code extension includes `zfls`, and is not affected; see [Editors](editors.md).
