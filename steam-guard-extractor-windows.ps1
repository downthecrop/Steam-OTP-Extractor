# steam-guard-extractor-windows.ps1
# Verified working logic parity with macOS flow.

$ErrorActionPreference = 'Stop'

function Bold($m)   { Write-Host $m -ForegroundColor Cyan }
function Info($m)   { Write-Host "👉 $m" }
function OK($m)     { Write-Host "✅ $m" -ForegroundColor Green }
function Warn($m)   { Write-Host "⚠️  $m" -ForegroundColor Yellow }
function Err($m)    { Write-Host "❌ $m" -ForegroundColor Red }
function Pause()    { Read-Host "Press Enter to continue..." | Out-Null }
function Confirm($q){ ($resp = Read-Host "$q [y/N]") -and $resp.ToLower().StartsWith('y') }

function Need($cmd) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Err "Missing '$cmd'. Please install it and re-run."
    exit 1
  }
}

$ScriptDir = Split-Path -LiteralPath $PSCommandPath -Parent
$WorkDir   = Join-Path $ScriptDir 'steam_guard_extractor_work'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Set-Location $WorkDir

Bold "Steam Guard Extractor (Windows)"
Info  "Working directory: $WorkDir"

# host requirements
foreach ($c in 'curl','tar','Expand-Archive','Invoke-WebRequest') {
  if ($c -eq 'curl') {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
      Warn "curl.exe not found; using Invoke-WebRequest."
    }
  } elseif ($c -eq 'Expand-Archive' -or $c -eq 'Invoke-WebRequest') {
    # built-in in PS5+
    continue
  } else {
    Need $c
  }
}

# architecture
$arch = ($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432 | Where-Object { $_ } | Select-Object -First 1)
switch ($arch.ToLower()) {
  'arm64' { $ADOPTIUM_ARCH = 'aarch64' }
  default { $ADOPTIUM_ARCH = 'x64' }
}
OK "Detected CPU architecture: $arch"

# sources
$ADOPTIUM_JRE_URL   = "https://api.adoptium.net/v3/binary/latest/11/ga/windows/$ADOPTIUM_ARCH/jre/hotspot/normal/adoptium"
$PLATFORM_TOOLS_URL = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
$ABE_URL            = "https://github.com/nelenkov/android-backup-extractor/releases/download/master-20221109063121-8fdfc5e/abe.jar"
$APKMIRROR_DL_URL   = "https://www.apkmirror.com/apk/valve-corporation/steam/steam-2-1-4-release/steam-2-1-4-android-apk-download/"
$PKG                = "com.valvesoftware.android.steam.community"

function Download-File($Url, $OutPath) {
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
  } catch {
    # fallback to curl if present
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
      & curl.exe -L -o $OutPath $Url
    } else {
      throw
    }
  }
}

function Find-JavaBin {
  $candidates = Get-ChildItem -Recurse -File -Filter 'java.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'bin\\java\.exe$' } |
    Select-Object -ExpandProperty DirectoryName
  $candidates | Select-Object -First 1
}

Bold "Step 1) Download a portable Java runtime (Temurin JRE 11)"
Info  "Downloading Temurin JRE 11 from Adoptium..."
$JreZip = Join-Path $WorkDir 'temurin-jre.zip'
Download-File $ADOPTIUM_JRE_URL $JreZip
Expand-Archive -Force -Path $JreZip -DestinationPath $WorkDir
$JavaBin = Find-JavaBin
if (-not $JavaBin) { Err "Could not locate java.exe after extraction."; exit 1 }
OK "Java found: $JavaBin"
& "$JavaBin\java.exe" -version | Out-Null

Bold "Step 2) Download Android Platform-Tools (adb)"
$PTZip = Join-Path $WorkDir 'platform-tools.zip'
Download-File $PLATFORM_TOOLS_URL $PTZip
if (Test-Path "$WorkDir\platform-tools") { Remove-Item -Recurse -Force "$WorkDir\platform-tools" }
Expand-Archive -Force -Path $PTZip -DestinationPath $WorkDir
$ADB = Join-Path $WorkDir 'platform-tools\adb.exe'
if (-not (Test-Path $ADB)) { Err "adb.exe not found after extraction."; exit 1 }
OK "adb ready: $ADB"

Bold "Step 3) Download Android Backup Extractor (abe.jar)"
$ABEPath = Join-Path $WorkDir 'abe.jar'
Download-File $ABE_URL $ABEPath
if (-not (Test-Path $ABEPath)) { Err "Failed to download abe.jar"; exit 1 }
OK "abe.jar downloaded."

Bold "Before we continue..."
@'
On your PHONE:

  • Uninstall the current Steam app (DO NOT remove Steam Guard / authenticator).
  • Enable Developer Options and USB debugging.
  • Connect the phone to this PC via USB.

We will verify ADB connectivity next.
'@ | Write-Host
Pause

Bold "Step 4) Connect phone & authorize ADB"
& $ADB kill-server *>$null 2>&1
& $ADB start-server *>$null 2>&1
& $ADB devices
Info "If you see 'unauthorized', unlock the phone and accept the USB debugging prompt, then press Enter to re-check."
Pause
$devices = (& $ADB devices) -split "`n" | Where-Object { $_ -match "`tdevice$" }
if (-not $devices) { Err "No authorized devices found. Check cable and USB debugging."; exit 1 }
OK ("Device(s) connected: " + ($devices -join ' '))

function Open-Url($u){ Start-Process $u | Out-Null }

function Find-ApkLoop {
  while ($true) {
    $cand = @()
    $cand += Get-ChildItem -Path $WorkDir   -File -Filter *.apk -ErrorAction SilentlyContinue
    $cand += Get-ChildItem -Path $ScriptDir -File -Filter *.apk -ErrorAction SilentlyContinue
    $cand = $cand | Select-Object -Unique

    if ($cand.Count -eq 0) {
      Warn "No APKs found beside the script or in: $WorkDir"
      Info "Opening the Steam 2.1.4 download page:"
      Write-Host "  $APKMIRROR_DL_URL"
      Open-Url $APKMIRROR_DL_URL
      Write-Host "Place the APK beside this script or into: $WorkDir"
      Pause
      continue
    }
    if ($cand.Count -eq 1) {
      $script:APKPath = $cand[0].FullName
      OK "Found single APK: $APKPath"
      return
    }
    Write-Host "Found APK(s):"
    for ($i=0; $i -lt $cand.Count; $i++) {
      Write-Host ("  [{0}] {1}" -f ($i+1), $cand[$i].FullName)
    }
    $sel = Read-Host "Pick a number"
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $cand.Count) {
      $script:APKPath = $cand[[int]$sel-1].FullName
      if (-not (Test-Path $APKPath)) { Err "APK vanished: $APKPath"; continue }
      OK "Using APK: $APKPath"
      return
    }
    Warn "Invalid selection."
  }
}

Bold "Step 5) Legacy Steam 2.1.4 APK"
Info  "Drop the APK beside this script or into: $WorkDir"
Find-ApkLoop

Bold "Step 6) Confirm you uninstalled Steam (but kept Steam Guard)"
if (-not (Confirm "Have you uninstalled the Steam app on your phone (without removing Steam Guard)?")) {
  Warn "Please uninstall it on the phone, then re-run."
  exit 1
}

Bold "Step 7) Install legacy Steam (with target-SDK bypass)"
Info  "We will try: adb install --bypass-low-target-sdk-block <apk>"
Info  "If it stalls/fails and your phone shows an 'older version' warning, tap:"
Info  "   'More info' -> 'Install anyway' (unlock if needed), then retry here."
$retries = 0
while ($true) {
  try {
    & $ADB install --bypass-low-target-sdk-block "$APKPath"
    break
  } catch {
    $retries++
    Warn "Install attempt #$retries failed."
    if (-not (Confirm "Did you tap 'More info' -> 'Install anyway' on the phone and want to retry?")) {
      Err "Install did not complete. Cannot continue."
      exit 1
    }
  }
}
OK "Legacy Steam installed."

Bold "Launching the legacy Steam app on your phone... (accept permissions)"
try { & $ADB shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 *> $null } catch {}
Info "(If you do not see it, launch Steam manually on your phone.)"
Pause

Bold "Step 8) Do the 'Please Help' recovery flow on the phone"
@'
On your phone, launch the Steam app:
  • If prompted: "This app was built for an older version of Android", tap "OK".
  • Log in with your account.
  • When asked for an authenticator code, tap "Please Help".
  • Tap "Use this device".
  • Tap "OK!" Send me the text message.
  • Verify with the SMS code, then Submit.
  • You should see an error screen with your current OTP code at the bottom.

VERY IMPORTANT: Now FULLY CLOSE the Steam app (swiped away) BEFORE we back up,
or the backup will be an ~1KB empty file and will not contain your secret.
'@ | Write-Host
Pause
if (-not (Confirm "Is the Steam app fully closed (swiped away)?")) {
  Warn "Please fully close it and re-run."
  exit 1
}

function Do-BackupOnce {
  if (Test-Path "$WorkDir\backup.ab") { Remove-Item -Force "$WorkDir\backup.ab" }
  & $ADB backup -noapk $PKG
  if (-not (Test-Path "$WorkDir\backup.ab")) { return 10 }
  $size = (Get-Item "$WorkDir\backup.ab").Length
  if ($size -lt 2048) { return 12 }
  return 0
}

function Backup-WithRetry {
  Bold "Step 9) Create Android backup of Steam data (adb backup)"
  Info  "You will see a BACKUP prompt on your phone. Leave the PASSWORD BLANK and confirm."
  Info  "Command: adb backup -noapk $PKG"

  $tries = 0; $maxtries = 5
  while ($tries -lt $maxtries) {
    $tries++
    Info "Attempt #$tries... Make sure the app is FULLY CLOSED (swiped away)."
    if (-not (Confirm "Is the Steam app fully closed?")) { Warn "Close it fully first."; continue }
    $rc = Do-BackupOnce
    if ($rc -eq 0) {
      $size = (Get-Item "$WorkDir\backup.ab").Length
      OK "Backup created: backup.ab ($size bytes)"
      return
    }
    Warn "Backup attempt #$tries failed or too small (~1KB trap)."
    if (Confirm "Run helper: kill & relaunch Steam via ADB so you can redo the on-phone steps?") {
      Bold "Helper: Kill & Relaunch Steam"
      Info "1) Relaunching the legacy Steam app for you..."
      try { & $ADB shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 *> $null } catch {}
      Info "2) On your phone: Login -> 'Please Help' -> 'Use this device' -> 'OK!' -> reach the screen with your code."
      Pause
      Info "3) Forcing the app to close so the backup contains your data..."
      try { & $ADB shell am force-stop $PKG *> $null } catch {}
      Info "App force-closed. We will retry backup."
    } else {
      Warn "Skipping helper; you can re-close the app yourself and retry."
    }
  }
  Err "Could not create a valid backup after $maxtries attempts."
  exit 1
}

Backup-WithRetry

Bold "Step 10) Unpack backup.ab to backup.tar"
if (Test-Path "$WorkDir\backup.tar") { Remove-Item -Force "$WorkDir\backup.tar" }
$unpacked = $true
try {
  & "$JavaBin\java.exe" -jar $ABEPath unpack "$WorkDir\backup.ab" "$WorkDir\backup.tar"
} catch { $unpacked = $false }
if (-not $unpacked -or -not (Test-Path "$WorkDir\backup.tar")) {
  Err "Failed to unpack with abe.jar. If you set a backup password, we must supply it."
  if (Confirm "Did you set a backup password on the phone? Provide it now?") {
    $BPPW = Read-Host -AsSecureString "Backup password (input hidden)"
    $BPPWPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($BPPW))
    try {
      & "$JavaBin\java.exe" -jar $ABEPath unpack "$WorkDir\backup.ab" "$WorkDir\backup.tar" "$BPPWPlain"
    } catch { Err "Unpack failed again."; exit 1 }
  } else { exit 1 }
}
$bytes = (Get-Item "$WorkDir\backup.tar").Length
OK "Unpacked to backup.tar ($bytes bytes)"

function Ensure-Extracted {
  if (Test-Path "$WorkDir\extracted") { Remove-Item -Recurse -Force "$WorkDir\extracted" }
  New-Item -ItemType Directory -Force -Path "$WorkDir\extracted" | Out-Null
  # use built-in bsdtar
  & tar -xf "$WorkDir\backup.tar" -C "$WorkDir\extracted"
}
Ensure-Extracted

function Convert-Base64ToBase32([string]$b64) {
  try {
    $bytes = [Convert]::FromBase64String($b64)
  } catch {
    return $null
  }
  $alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  [int]$bits = 0
  [int]$value = 0
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) {
    $value = (($value -shl 8) -bor $b)
    $bits += 8
    while ($bits -ge 5) {
      $index = ($value -shr ($bits - 5)) -band 0x1F
      $null = $sb.Append($alphabet[$index])
      $bits -= 5
    }
  }
  if ($bits -gt 0) {
    $index = (($value -shl (5 - $bits)) -band 0x1F)
    $null = $sb.Append($alphabet[$index])
  }
  $sb.ToString()
}

function UrlEncode-Min([string]$s) {
  $s.Replace(' ','%20').Replace('@','%40').Replace(':','%3A').Replace('/','%2F')
}

function Get-QueryValue([string]$url,[string]$key) {
  if ($url -notmatch '\?') { return $null }
  $qs = $url.Split('?',2)[1]
  foreach ($kv in $qs -split '&') {
    $pair = $kv.Split('=',2)
    if ($pair[0] -eq $key) { return $pair[1] }
  }
  return $null
}

function Extract-And-Print-Secrets {
  Bold "Step 11) Find Steam Guard secret(s)"
  $steamF = Join-Path $WorkDir ("extracted/apps/{0}/f" -f $PKG)
  if (-not (Test-Path $steamF)) { Err "Expected directory not found: $steamF"; exit 1 }

  $sgFiles = Get-ChildItem -Path $steamF -Filter 'Steamguard-*' -File -ErrorAction SilentlyContinue | Sort-Object FullName
  if (-not $sgFiles) { Err "No Steamguard-* files found. The backup may be incomplete."; exit 1 }

  $found = 0
  foreach ($f in $sgFiles) {
    # Strip NULs
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $cleanBytes = $bytes | Where-Object { $_ -ne 0 }
    $clean = [Text.Encoding]::UTF8.GetString($cleanBytes)

    $obj = $null
    try { $obj = $clean | ConvertFrom-Json -ErrorAction Stop } catch {}

    $uri            = $null
    $account_name   = $null
    $steamid        = $null
    $shared_secret  = $null
    $identity_secret= $null

    if ($obj) {
      $uri             = $obj.uri
      $account_name    = $obj.account_name
      $steamid         = $obj.steamid
      $shared_secret   = $obj.shared_secret
      $identity_secret = $obj.identity_secret
    } else {
      # fallback regex
      $uri             = [regex]::Match($clean, '"uri"\s*:\s*"([^"]*)"').Groups[1].Value
      $account_name    = [regex]::Match($clean, '"account_name"\s*:\s*"([^"]*)"').Groups[1].Value
      $steamid         = [regex]::Match($clean, '"steamid"\s*:\s*"([^"]*)"').Groups[1].Value
      $shared_secret   = [regex]::Match($clean, '"shared_secret"\s*:\s*"([^"]*)"').Groups[1].Value
      $identity_secret = [regex]::Match($clean, '"identity_secret"\s*:\s*"([^"]*)"').Groups[1].Value
    }

    $secret = $null
    if ($uri) {
      $uriUnesc = $uri -replace '\\/','/'
      $secret = Get-QueryValue $uriUnesc 'secret'
    }
    if (-not $secret) {
      $m = [regex]::Match($clean, 'secret=([A-Z2-7]+)')
      if ($m.Success) { $secret = $m.Groups[1].Value }
    }
    if (-not $secret -and $shared_secret) {
      $secret = Convert-Base64ToBase32 $shared_secret
    }

    if ($secret -or $shared_secret -or $identity_secret -or $uri) {
      $found++
      Write-Host ""
      OK ("Found Steamguard file: {0}" -f $f.FullName)
      if ($account_name)    { Write-Host ("account_name:       {0}" -f $account_name) }
      if ($steamid)         { Write-Host ("steamid:            {0}" -f $steamid) }
      if ($secret)          { Write-Host ("secret (TOTP):      {0}" -f $secret) }
      if ($uri)             { Write-Host ("uri (from file):    {0}" -f ($uri -replace '\\/','/')) }
      if ($shared_secret)   { Write-Host ("shared_secret:      {0}" -f $shared_secret) }
      if ($identity_secret) { Write-Host ("identity_secret:     {0}" -f $identity_secret) }

      if ($secret) {
        $label = "Steam"
        if ($account_name) { $label = "Steam:$account_name" }
        elseif ($steamid)  { $label = "Steam:$steamid" }

        $labelEnc = UrlEncode-Min $label
        $otpauth  = "otpauth://totp/$labelEnc?secret=$secret&issuer=Steam"
        $steamUri = "steam://$secret"
        Write-Host ("steam-uri:         {0}" -f $steamUri)
        Write-Host ("otpauth-universal: {0}" -f $otpauth)
      }
    }
  }

  if ($found -eq 0) {
    Err "No secrets found. Inspect files under: $steamF"
    exit 1
  }
}

Extract-And-Print-Secrets

Write-Host ""
Bold "All done!"
Info "You now have both 'steam-uri' and 'otpauth-universal' above for importing to your OTP app."

# One-shot cleanup
if (Confirm "Clean up ALL artifacts and tools now? (backups + extracted files + JRE + platform-tools + abe.jar)") {
  Remove-Item -Force -ErrorAction SilentlyContinue `
    "$WorkDir\backup.ab","$WorkDir\backup.tar","$WorkDir\temurin-jre.zip","$WorkDir\platform-tools.zip","$WorkDir\abe.jar"
  if (Test-Path "$WorkDir\extracted")        { Remove-Item -Recurse -Force "$WorkDir\extracted" }
  if (Test-Path "$WorkDir\platform-tools")   { Remove-Item -Recurse -Force "$WorkDir\platform-tools" }
  Get-ChildItem -Directory -Path $WorkDir | Where-Object { $_.Name -match 'jdk|jre|Temurin|adoptium' } | ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
  OK "Everything cleaned up."
} else {
  Warn "Remember: backup files and extracted data are sensitive. Delete them when finished."
}

OK "Script finished successfully."
Write-Host "OK You may now update the Steam app to the latest version through the Google Play Store."

