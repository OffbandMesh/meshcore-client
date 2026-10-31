#Requires -Version 7.2
<#
.SYNOPSIS
  Apple Distribution signing material for Offband Meshcore, made on Windows (#1017, epic #1012).

.DESCRIPTION
  Replaces the Mac-only Keychain Access steps with openssl, so the owner never
  needs a Mac. Everything secret lives in a work folder OUTSIDE the repository
  (default: <your user folder>\.offband-ios). Nothing this script does prints a
  password, a key or a certificate.

  new-csr      Make the private key and the certificate signing request to upload to Apple.
  make-p12     Turn the certificate Apple returns (.cer) into a password-protected .p12.
  set-secrets  Store the .p12, its password, the provisioning profile and the
               App Store Connect API key as GitHub secrets in the apple-signing Environment.
  selftest     Run new-csr's key step and make-p12 against a throwaway self-signed
               certificate in a temporary folder. Used by CI; touches no real file.

  Every step stops on the first thing it cannot confirm.

.EXAMPLE
  .\tools\ios-signing\ios-signing.ps1 new-csr
  .\tools\ios-signing\ios-signing.ps1 make-p12 -Cer "$HOME\Downloads\distribution.cer"
  .\tools\ios-signing\ios-signing.ps1 set-secrets -ProvisioningProfile "$HOME\Downloads\Offband_App_Store.mobileprovision" -ApiKey "$HOME\Downloads\AuthKey_ABC123XYZ9.p8" -IssuerId "<issuer id from App Store Connect>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('new-csr', 'make-p12', 'set-secrets', 'selftest')]
    [string]$Command,

    [string]$WorkDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.offband-ios'),
    [string]$Email = 'support@offband.org',
    [string]$Cer,
    [string]$ProvisioningProfile,
    [string]$ApiKey,
    [string]$IssuerId,
    [string]$Repo = 'OffbandMesh/meshcore-client',
    [string]$Environment = 'apple-signing'
)

$ErrorActionPreference = 'Stop'
# Exit codes are checked explicitly after every native call; this keeps the
# DER-then-PEM fallback below from throwing on its first, expected failure.
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$CommonName = 'Offband Meshcore Distribution'
# Git for Windows ships an MSYS openssl in usr\bin that rewrites arguments
# starting with "/" (such as -subj "/CN=...") into Windows paths. Prefer the
# mingw64 build, and switch the rewriting off in case the MSYS one is used.
$env:MSYS2_ARG_CONV_EXCL = '*'

function Stop-Step([string]$Message) {
    throw "STOPPED: $Message"
}

function Find-OpenSsl {
    if ($env:OPENSSL) {
        if (Test-Path -LiteralPath $env:OPENSSL) { return $env:OPENSSL }
        Stop-Step "OPENSSL is set to '$($env:OPENSSL)', which does not exist."
    }
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe' }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $onPath = Get-Command openssl -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    Stop-Step 'openssl not found. Install Git for Windows, or set OPENSSL to the full path of openssl.exe.'
}

function Invoke-OpenSsl([string[]]$Arguments) {
    $out = & $script:OpenSsl @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Step "openssl $($Arguments[0]) failed (exit $LASTEXITCODE): $($out | Select-Object -Last 3 | Out-String)"
    }
    return $out
}

function Assert-File([string]$Path, [string]$What) {
    if (-not $Path) { Stop-Step "$What was not given." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Step "$What not found at '$Path'." }
    if ((Get-Item -LiteralPath $Path).Length -eq 0) { Stop-Step "$What at '$Path' is empty." }
}

function New-Password {
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function New-Key([string]$Dir) {
    $key = Join-Path $Dir 'dist.key'
    if (Test-Path -LiteralPath $key) {
        Stop-Step "A private key already exists at '$key'. It may already belong to a certificate, so it is never overwritten. Move it aside yourself if you really mean to start over."
    }
    Invoke-OpenSsl @('genrsa', '-out', $key, '2048') | Out-Null
    return $key
}

function Build-P12([string]$Dir, [string]$CerPath) {
    $key = Join-Path $Dir 'dist.key'
    $pem = Join-Path $Dir 'dist.pem'
    $p12 = Join-Path $Dir 'dist.p12'
    $pwFile = Join-Path $Dir 'p12-password.txt'
    Assert-File $key 'The private key from new-csr'
    Assert-File $CerPath 'The certificate from Apple (.cer)'
    if (Test-Path -LiteralPath $p12) { Stop-Step "'$p12' already exists and is never overwritten." }

    # Apple's download is DER; accept PEM too, and stop if it is neither.
    & $script:OpenSsl x509 -inform DER -in $CerPath -out $pem 2>$null
    if ($LASTEXITCODE -ne 0) {
        & $script:OpenSsl x509 -inform PEM -in $CerPath -out $pem 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Step "'$CerPath' is not a certificate openssl can read." }
    }

    # A certificate issued for a different key would produce a .p12 that cannot sign.
    $certMod = (Invoke-OpenSsl @('x509', '-noout', '-modulus', '-in', $pem)) -join ''
    $keyMod = (Invoke-OpenSsl @('rsa', '-noout', '-modulus', '-in', $key)) -join ''
    if ($certMod -ne $keyMod) {
        Stop-Step 'This certificate was not issued for the private key in the work folder. Use the .cer made from this folder''s CSR.'
    }

    $pw = New-Password
    [System.IO.File]::WriteAllText($pwFile, $pw)
    # Legacy PKCS#12 encryption (3DES, SHA-1 MAC). OpenSSL 3's default is
    # AES-256 with a SHA-256 MAC, reported as refused by older macOS keychain
    # tooling. .github/workflows/ios-signing-proof.yml records what the runner
    # does with each. Keep these flags identical to that workflow.
    Invoke-OpenSsl @('pkcs12', '-export', '-inkey', $key, '-in', $pem, '-name', $CommonName,
        '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
        '-out', $p12, '-passout', "file:$pwFile") | Out-Null

    # Read it back with the stored password, so a bad pack is caught here, not in CI.
    Invoke-OpenSsl @('pkcs12', '-info', '-noout', '-in', $p12, '-passin', "file:$pwFile") | Out-Null
    return $p12
}

function Set-Secret([string]$Name, [string]$Value) {
    if (-not $Value) { Stop-Step "Refusing to set $Name to an empty value." }
    # Piped on stdin: gh trims the trailing newline PowerShell adds, and the
    # value never appears on a command line.
    $Value | gh secret set $Name --env $Environment --repo $Repo
    if ($LASTEXITCODE -ne 0) { Stop-Step "gh secret set $Name failed (exit $LASTEXITCODE)." }
    Write-Host "  set $Name"
}

$script:OpenSsl = Find-OpenSsl

switch ($Command) {
    'new-csr' {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
        $key = New-Key $WorkDir
        $csr = Join-Path $WorkDir 'dist.certSigningRequest'
        Invoke-OpenSsl @('req', '-new', '-key', $key, '-out', $csr,
            '-subj', "/emailAddress=$Email/CN=$CommonName/C=US") | Out-Null
        Assert-File $csr 'The certificate signing request'
        Write-Host "Done. Upload this file to Apple when it asks for a certificate signing request:"
        Write-Host "  $csr"
    }
    'make-p12' {
        $p12 = Build-P12 $WorkDir $Cer
        Write-Host "Done. Signing bundle made and checked: $p12"
        Write-Host "Its password is stored next to it and is never shown."
    }
    'set-secrets' {
        $p12 = Join-Path $WorkDir 'dist.p12'
        $pwFile = Join-Path $WorkDir 'p12-password.txt'
        Assert-File $p12 'The .p12 from make-p12'
        Assert-File $pwFile 'The .p12 password file from make-p12'
        Assert-File $ProvisioningProfile 'The provisioning profile (.mobileprovision)'
        Assert-File $ApiKey 'The App Store Connect API key (.p8)'
        if (-not $IssuerId) { Stop-Step 'The issuer ID from App Store Connect was not given.' }
        $leaf = Split-Path -Leaf $ApiKey
        if ($leaf -notmatch '^AuthKey_([A-Z0-9]+)\.p8$') {
            Stop-Step "Expected the key file Apple names AuthKey_<KEYID>.p8, got '$leaf'."
        }
        $keyId = $Matches[1]
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Stop-Step 'gh (GitHub CLI) not found.' }

        Write-Host "Setting secrets in Environment '$Environment' of $Repo (names only are shown):"
        Set-Secret 'APPLE_DIST_P12_BASE64' ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p12)))
        Set-Secret 'APPLE_DIST_P12_PASSWORD' ([System.IO.File]::ReadAllText($pwFile))
        Set-Secret 'APPLE_PROFILE_BASE64' ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ProvisioningProfile)))
        Set-Secret 'ASC_API_KEY_P8_BASE64' ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ApiKey)))
        Set-Secret 'ASC_API_KEY_ID' $keyId
        Set-Secret 'ASC_API_ISSUER_ID' $IssuerId
        Write-Host 'Done. All six secrets are set.'
    }
    'selftest' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("offband-ios-selftest-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $key = New-Key $dir
            # A throwaway self-signed certificate standing in for Apple's, in Apple's DER form.
            $selfPem = Join-Path $dir 'self.pem'
            $selfCer = Join-Path $dir 'self.cer'
            Invoke-OpenSsl @('req', '-x509', '-new', '-key', $key, '-days', '1', '-out', $selfPem, '-subj', "/CN=$CommonName") | Out-Null
            Invoke-OpenSsl @('x509', '-in', $selfPem, '-outform', 'DER', '-out', $selfCer) | Out-Null
            $p12 = Build-P12 $dir $selfCer

            # The checks above must be able to fail: a certificate for another key must be refused.
            $otherKey = Join-Path $dir 'other.key'
            $otherPem = Join-Path $dir 'other.pem'
            Invoke-OpenSsl @('genrsa', '-out', $otherKey, '2048') | Out-Null
            Invoke-OpenSsl @('req', '-x509', '-new', '-key', $otherKey, '-days', '1', '-out', $otherPem, '-subj', '/CN=other') | Out-Null
            Remove-Item -LiteralPath $p12
            $refused = $false
            try { Build-P12 $dir $otherPem | Out-Null } catch { $refused = $_.Exception.Message -like 'STOPPED: This certificate was not issued*' }
            if (-not $refused) { Stop-Step 'selftest: a certificate for a different key was NOT refused.' }

            Remove-Item -LiteralPath (Join-Path $dir 'p12-password.txt') -ErrorAction SilentlyContinue
            $p12 = Build-P12 $dir $selfCer
            if ($env:SELFTEST_OUT) {
                Copy-Item -LiteralPath $p12 -Destination (Join-Path $env:SELFTEST_OUT 'selftest.p12')
                Copy-Item -LiteralPath (Join-Path $dir 'p12-password.txt') -Destination (Join-Path $env:SELFTEST_OUT 'selftest-password.txt')
            }
            Write-Host 'selftest passed: key, DER certificate, key match, legacy .p12, read-back, and refusal of a mismatched certificate.'
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
