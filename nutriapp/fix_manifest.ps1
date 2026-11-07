# Adds the two Android settings `flutter create` leaves out of the release
# manifest, then tells you what it changed.
#
#     powershell -ExecutionPolicy Bypass -File .\fix_manifest.ps1
#
# Safe to run twice: it skips anything already present. Keeps a .bak of the
# original the first time it changes something.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- find the app
$candidates = @(
    (Get-Location).Path,
    (Join-Path (Get-Location).Path 'nutriapp'),
    (Split-Path (Get-Location).Path -Parent),
    (Join-Path (Split-Path (Get-Location).Path -Parent) 'nutriapp')
)
if ($PSScriptRoot) {
    $candidates += $PSScriptRoot
    $candidates += (Join-Path $PSScriptRoot 'nutriapp')
}

$app = $null
foreach ($dir in $candidates) {
    if ($dir -and (Test-Path (Join-Path $dir 'pubspec.yaml'))) { $app = $dir; break }
}
if (-not $app) {
    Write-Host "Could not find pubspec.yaml near $((Get-Location).Path)."
    exit 1
}
$app = (Resolve-Path $app).Path
$manifest = Join-Path $app 'android\app\src\main\AndroidManifest.xml'

if (-not (Test-Path $manifest)) {
    Write-Host "No manifest at $manifest"
    Write-Host "Run:  flutter create . --platforms android"
    exit 1
}

Write-Host ""
Write-Host "Manifest: $manifest"
Write-Host ""

$text = Get-Content -Raw -Path $manifest
$original = $text
$changed = @()

# ------------------------------------------------- 1. the INTERNET permission
if ($text -match 'android\.permission\.INTERNET') {
    Write-Host "already there   INTERNET permission"
} else {
    # Insert immediately after the <manifest ...> opening tag, whatever
    # attributes it carries.
    if ($text -notmatch '(?s)(<manifest\b[^>]*>)') {
        Write-Host "PROBLEM         could not find the <manifest> tag -- edit by hand"
        exit 1
    }
    $text = [regex]::Replace(
        $text,
        '(?s)(<manifest\b[^>]*>)',
        "`$1`r`n    <uses-permission android:name=`"android.permission.INTERNET`"/>",
        1)
    $changed += 'added the INTERNET permission'
    Write-Host "added           INTERNET permission"
}

# --------------------------------------------------------- 2. cleartext HTTP
if ($text -match 'usesCleartextTraffic') {
    Write-Host "already there   usesCleartextTraffic"
} else {
    if ($text -notmatch '<application\b') {
        Write-Host "PROBLEM         could not find the <application> tag -- edit by hand"
        exit 1
    }
    # Append as a new attribute on <application, before its existing ones, so
    # indentation of the rest is untouched.
    $text = [regex]::Replace(
        $text,
        '<application\b',
        "<application`r`n        android:usesCleartextTraffic=`"true`"",
        1)
    $changed += 'allowed cleartext HTTP'
    Write-Host "added           usesCleartextTraffic (remove once the server is https://)"
}

# ------------------------------------------------------------------ write out
Write-Host ""
if ($text -eq $original) {
    Write-Host "Nothing to change. Both settings were already in place."
    exit 0
}

$backup = "$manifest.bak"
if (-not (Test-Path $backup)) {
    Set-Content -Path $backup -Value $original -NoNewline
    Write-Host "Original saved to AndroidManifest.xml.bak"
}
Set-Content -Path $manifest -Value $text -NoNewline

Write-Host ""
Write-Host "The file now begins:"
Write-Host ""
(Get-Content -Path $manifest -TotalCount 8) | ForEach-Object { Write-Host "    $_" }
Write-Host ""
Write-Host "Done: $($changed -join ', ')."
Write-Host "Re-run check_after_create.ps1 -- all checks should pass now."
