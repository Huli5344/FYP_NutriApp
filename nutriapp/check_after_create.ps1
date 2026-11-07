# Checks a Nutri App working copy after `flutter create .`.
#
# Run it from anywhere inside or beside the project:
#
#     powershell -ExecutionPolicy Bypass -File .\check_after_create.ps1
#
# It finds the Flutter app folder itself rather than trusting the directory you
# happen to be in -- the first version of this script did trust it, got run one
# level too high, and reported "ok" against files it had never looked at.

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- find the app
# Look for the folder holding pubspec.yaml: here, in .\nutriapp, beside us, or
# in the script's own folder and its nutriapp subfolder.
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
    Write-Host ""
    Write-Host "Could not find pubspec.yaml near $((Get-Location).Path)."
    Write-Host "Run this from the project folder, or from the nutriapp folder inside it."
    exit 1
}

$app = (Resolve-Path $app).Path
$root = (Resolve-Path (Join-Path $app '..')).Path

Write-Host ""
Write-Host "Flutter app:   $app"
Write-Host "Project root:  $root"
Write-Host ""

# ------------------------------------------------------------------- the checks
$problems = @()

function Say($status, $label, $fix) {
    Write-Host ("{0,-9} {1}" -f $status, $label)
    if ($status -eq 'PROBLEM') { $script:problems += ,@($label, $fix) }
}

function CheckText($label, $relative, $pattern, $wanted, $fix) {
    $file = Join-Path $app $relative
    if (-not (Test-Path $file)) {
        Say 'MISSING' "$label  [$relative not found]" $fix
        return
    }
    $found = [bool](Select-String -Path $file -Pattern $pattern -SimpleMatch -Quiet)
    if ($found -eq $wanted) { Say 'ok' $label $null } else { Say 'PROBLEM' $label $fix }
}

function CheckPath($label, $relative, $wanted, $fix) {
    $exists = Test-Path (Join-Path $app $relative)
    if ($exists -eq $wanted) { Say 'ok' $label $null } else { Say 'PROBLEM' $label $fix }
}

Write-Host "Files flutter create can overwrite"
CheckText 'the foods.db asset is still declared' 'pubspec.yaml' 'assets/foods.db' $true `
    'Restore pubspec.yaml from the zip. Without this line the food database is not bundled and search returns nothing.'
CheckText 'the dependencies survived' 'pubspec.yaml' 'sqflite' $true `
    'Restore pubspec.yaml from the zip.'
CheckText 'main.dart is yours, not the template' 'lib\main.dart' 'StartupGate' $true `
    'Restore lib/main.dart from the zip -- flutter create replaced it with the counter demo.'
CheckText 'widget_test.dart was not clobbered' 'test\widget_test.dart' 'Counter increments' $false `
    'Restore test/widget_test.dart from the zip -- the template version references a MyApp class this project does not have, and flutter analyze reports it as an error.'

Write-Host ""
Write-Host "Things that must be present to build"
CheckPath 'the food database is in assets' 'assets\foods.db' $true `
    'Copy foods.db into nutriapp\assets\. 2,692 foods, about 1.2 MB.'
CheckPath 'the Android project exists' 'android\app\src\main\AndroidManifest.xml' $true `
    'Run: flutter create . --platforms android   (from the folder with pubspec.yaml)'

Write-Host ""
Write-Host "Android manifest"
CheckText 'the INTERNET permission is declared' `
    'android\app\src\main\AndroidManifest.xml' 'android.permission.INTERNET' $true `
    'Add <uses-permission android:name="android.permission.INTERNET"/> inside <manifest>, before <application>. flutter create puts it only in the debug manifest, so a release APK has no network at all -- and this app fails silently on network errors, so nothing on screen would tell you why.'
CheckText 'cleartext HTTP is allowed' `
    'android\app\src\main\AndroidManifest.xml' 'usesCleartextTraffic' $true `
    'Add android:usesCleartextTraffic="true" to the <application> tag. Needed only while the server is http:// -- delete it once you are on the https:// Render URL.'

# --------------------------------------------------------------- the local half
Write-Host ""
Write-Host "Project layout"
$hasBackend  = Test-Path (Join-Path $root 'backend\app.py')
$hasRender   = Test-Path (Join-Path $root 'render.yaml')
$hasTools    = Test-Path (Join-Path $root 'tools')
if ($hasBackend) { Say 'ok' 'backend is one level up' $null }
else { Say 'PROBLEM' 'backend is one level up' "Expected $root\backend\app.py. The extraction may have nested differently." }
if ($hasRender) { Say 'ok' 'render.yaml is at the project root' $null }
else { Say 'PROBLEM' 'render.yaml is at the project root' "Expected $root\render.yaml. Render's blueprint only looks at the top level of the repository." }
if ($hasTools) { Say 'ok' 'tools is one level up' $null }
else { Say 'PROBLEM' 'tools is one level up' "Expected $root\tools." }

# How many Flutter projects are under the root? More than one is the mistake
# that wasted an afternoon: flutter run picks whichever folder you are in.
$pubspecs = @(Get-ChildItem -Path $root -Recurse -Depth 2 -Filter pubspec.yaml -ErrorAction SilentlyContinue)
if ($pubspecs.Count -eq 1) {
    Say 'ok' 'exactly one Flutter project under the root' $null
} else {
    Say 'PROBLEM' "$($pubspecs.Count) pubspec.yaml files under the root" `
        ("Delete the stray project. Found: " + (($pubspecs | ForEach-Object { $_.FullName }) -join '; '))
}

# Platform folders nobody asked for. Not a problem, just noise in the repo.
$extra = @('ios','web','windows','linux','macos') |
    Where-Object { Test-Path (Join-Path $app $_) }
Write-Host ""
if ($extra.Count -gt 0) {
    Write-Host ("note      flutter create also made: " + ($extra -join ', ') +
                " -- safe to delete if you only target Android")
}

# ------------------------------------------------------------------- the verdict
Write-Host ""
if ($problems.Count -eq 0) {
    Write-Host "All checks passed. Next:"
    Write-Host "    cd `"$app`""
    Write-Host "    flutter pub get"
    Write-Host "    flutter analyze"
    Write-Host "    flutter test"
    exit 0
}

Write-Host "$($problems.Count) problem(s) to fix:"
Write-Host ""
foreach ($p in $problems) {
    Write-Host "  - $($p[0])"
    Write-Host "    $($p[1])"
    Write-Host ""
}
exit 1
