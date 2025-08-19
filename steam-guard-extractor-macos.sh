#!/usr/bin/env bash
set -euo pipefail

# =========================
# Steam Guard Extractor (macOS)
# =========================
# - Downloads portable Temurin JRE 11 (local-only)
# - Downloads Android Platform-Tools (adb)
# - Downloads known working Android Backup Extractor (abe.jar)
# - Guides you step-by-step, verifies at each step, fails fast with clear hints
# - Extracts Steam Guard TOTP secret(s) from backup.tar
# - Prints BOTH import formats:
#       steam://<SECRET>
#       otpauth://totp/<Label>?secret=<SECRET>&issuer=Steam
#
# You MUST provide the legacy Steam 2.1.4 APK.
# Just drop it either:
#   • beside this .sh script, or
#   • inside: ./steam_guard_extractor_work/
# The script will loop until it detects the APK (no full path required).
#
# Sensitive: your secret is like a password; keep it private.

bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
info()   { printf "👉 %s\n" "$*"; }
ok()     { printf "✅ %s\n" "$*"; }
warn()   { printf "⚠️  %s\n" "$*"; }
err()    { printf "❌ %s\n" "$*" >&2; }
pause()  { read -r -p "Press Enter to continue..."; }
confirm(){ read -r -p "$1 [y/N]: " _ans; [[ "${_ans:-}" =~ ^[Yy]$ ]]; }
need()   { command -v "$1" >/dev/null 2>&1 || { err "Missing '$1'. Install it and re-run."; exit 1; }; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${SCRIPT_DIR}/steam_guard_extractor_work"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

bold "Steam Guard Extractor (macOS)"
info  "Working directory: $WORKDIR"

# host requirements
for cmd in curl unzip tar sed awk grep base64 xxd tr; do need "$cmd"; done

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ADOPTIUM_ARCH="x64" ;;
  arm64)   ADOPTIUM_ARCH="aarch64" ;;
  *) err "Unsupported CPU architecture: $ARCH"; exit 1 ;;
esac
ok "Detected CPU architecture: $ARCH"

# sources
ADOPTIUM_JRE_URL="https://api.adoptium.net/v3/binary/latest/11/ga/mac/${ADOPTIUM_ARCH}/jre/hotspot/normal/adoptium"
PLATFORM_TOOLS_URL="https://dl.google.com/android/repository/platform-tools-latest-darwin.zip"
ABE_URL="https://github.com/nelenkov/android-backup-extractor/releases/download/master-20221109063121-8fdfc5e/abe.jar"
APKMIRROR_DL_URL="https://www.apkmirror.com/apk/valve-corporation/steam/steam-2-1-4-release/steam-2-1-4-android-apk-download/"
PKG="com.valvesoftware.android.steam.community"

# ---------- helpers ----------
safegrep() { set +e; grep -a -o "$1" "$2" 2>/dev/null; local rc=$?; set -e; return $rc; }

get_query_param() {  # get_query_param key url
  local key="$1" url="$2"
  echo "$url" | awk -v k="$key" -F'?' 'NF>1{print $2}' | tr '&' '\n' | awk -F'=' -v k="$key" '$1==k{print $2}' | head -n1
}

url_encode_min() { echo "$1" | sed -E 's/ /%20/g; s/@/%40/g; s/:/%3A/g; s/\//%2F/g'; }

launch_app() { set +e; "$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; set -e; }
force_stop_app(){ set +e; "$ADB" shell am force-stop "$PKG" >/dev/null 2>&1; set -e; }

# Base64(shared_secret) -> Base32 (RFC 4648, no padding) with POSIX tools
b64_to_base32() {
  local b64="$1" tmp
  tmp="$(mktemp)"
  # macOS base64 uses -D; GNU uses -d. Try both.
  if ! printf '%s' "$b64" | base64 -D >"$tmp" 2>/dev/null; then
    if ! printf '%s' "$b64" | base64 -d >"$tmp" 2>/dev/null; then
      rm -f "$tmp"; return 1
    fi
  fi
  local bits; bits="$(xxd -b -c1 "$tmp" | awk '{print $2}' | tr -d '\n')"
  rm -f "$tmp"
  local rem=$(( ${#bits} % 5 ))
  if (( rem != 0 )); then bits="${bits}$(printf '0%.0s' $(seq 1 $((5-rem))))"; fi
  local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  local out="" i=0
  while (( i < ${#bits} )); do
    local group="${bits:$i:5}"
    local idx=$((2#$group))
    out="${out}${alphabet:idx:1}"
    i=$((i+5))
  done
  printf '%s\n' "$out"
}

find_apk_loop() {
  # Look in both script dir and work dir; loop until an APK appears
  while true; do
    mapfile -t CANDIDATES < <(
      { find "$WORKDIR"    -maxdepth 1 -type f -name "*.apk" 2>/dev/null;
        find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.apk" 2>/dev/null; } | sort -u
    )
    if (( ${#CANDIDATES[@]} == 0 )); then
      warn "No APKs found beside the script or in: $WORKDIR"
      info "Opening the Steam 2.1.4 download page:"
      echo "  $APKMIRROR_DL_URL"
      command -v open >/dev/null 2>&1 && open "$APKMIRROR_DL_URL"
      echo "Place the APK beside this script or into: $WORKDIR"
      pause
      continue
    fi
    if (( ${#CANDIDATES[@]} == 1 )); then
      APK_PATH="${CANDIDATES[0]}"
      ok "Found single APK: $APK_PATH"
      return 0
    fi
    echo "Found APK(s):"
    local i=1
    for a in "${CANDIDATES[@]}"; do printf "  [%d] %s\n" "$i" "$a"; i=$((i+1)); done
    read -r -p "Pick a number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#CANDIDATES[@]} )); then
      APK_PATH="${CANDIDATES[$((choice-1))]}"
      [[ -f "$APK_PATH" ]] || { err "APK vanished: $APK_PATH"; continue; }
      ok "Using APK: $APK_PATH"
      return 0
    fi
    warn "Invalid selection."
  done
}

do_backup_once() {
  rm -f backup.ab
  set +e
  "$ADB" backup -noapk "$PKG"
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || return 10
  [[ -s backup.ab ]] || return 11
  local size
  size=$(stat -f%z backup.ab 2>/dev/null || stat -c%s backup.ab 2>/dev/null || echo 0)
  [[ "$size" -ge 2048 ]] || return 12
  return 0
}

backup_with_retry() {
  bold "Step 9) Create Android backup of Steam data (adb backup)"
  info  "You will see a BACKUP prompt on your phone. Leave the PASSWORD BLANK and confirm."
  info  "Command: adb backup -noapk $PKG"

  local tries=0
  local maxtries=5
  while (( tries < maxtries )); do
    tries=$((tries+1))
    info "Attempt #$tries... Make sure the app is FULLY CLOSED (swiped away)."
    confirm "Is the Steam app fully closed?" || { warn "Close it fully first."; continue; }

    if do_backup_once; then
      local SIZE
      SIZE=$(stat -f%z backup.ab 2>/dev/null || stat -c%s backup.ab 2>/dev/null || echo 0)
      ok "Backup created: backup.ab (${SIZE} bytes)"
      return 0
    fi

    warn "Backup attempt #$tries failed or too small (~1KB trap)."
    if confirm "Run helper: kill & relaunch Steam via ADB so you can redo the on-phone steps?"; then
      bold "Helper: Kill & Relaunch Steam"
      info "1) Relaunching the legacy Steam app for you..."
      launch_app
      info "2) On your phone: Login -> \"Please Help\" -> \"Use this device\" -> \"OK!\" -> reach the screen with your code."
      pause
      info "3) Forcing the app to close so the backup contains your data..."
      force_stop_app
      info "App force-closed. We will retry backup."
    else
      warn "Skipping helper; you can re-close the app yourself and retry."
    fi
  done

  err "Could not create a valid backup after $maxtries attempts."
  return 1
}

extract_and_print_secrets() {
  bold "Step 11) Extract files and find Steam Guard secret(s)"
  rm -rf extracted
  mkdir -p extracted
  tar -xf backup.tar -C extracted

  local steam_f_dir="extracted/apps/${PKG}/f"
  [[ -d "$steam_f_dir" ]] || { err "Expected directory not found: $steam_f_dir"; exit 1; }

  mapfile -t sg_files < <(find "$steam_f_dir" -type f -name 'Steamguard-*' | sort)
  if [[ ${#sg_files[@]} -eq 0 ]]; then
    err "No Steamguard-* files found. The backup may be incomplete."
    exit 1
  fi

  local found=0
  for f in "${sg_files[@]}"; do
    # Some Steamguard files include NUL bytes; strip them before parsing
    local clean; clean="$(mktemp)"
    LC_ALL=C tr -d '\000' < "$f" > "$clean"

    # Try to pull fields from cleaned JSON-ish content
    set +e
    local uri_line account_name steamid shared_secret identity_secret
    uri_line="$(grep -ao '"uri"[[:space:]]*:[[:space:]]*"[^"]*"' "$clean" | sed -E 's/.*"uri"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n1)"
    account_name="$(grep -ao '"account_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$clean" | sed -E 's/.*"account_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n1)"
    steamid="$(grep -ao '"steamid"[[:space:]]*:[[:space:]]*"[^"]*"' "$clean" | sed -E 's/.*"steamid"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n1)"
    shared_secret="$(grep -ao '"shared_secret"[[:space:]]*:[[:space:]]*"[^"]*"' "$clean" | sed -E 's/.*"shared_secret"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n1)"
    identity_secret="$(grep -ao '"identity_secret"[[:space:]]*:[[:space:]]*"[^"]*"' "$clean" | sed -E 's/.*"identity_secret"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -n1)"
    set -e

    local secret="" uri=""
    if [[ -n "${uri_line:-}" ]]; then
      uri="$(printf '%s' "$uri_line" | sed 's#\\/#/#g')"
      secret="$(get_query_param "secret" "$uri")"
    fi
    if [[ -z "$secret" ]]; then
      set +e
      local raw
      raw="$(grep -ao 'secret=[A-Z2-7]+' "$clean" | head -n1)"
      set -e
      secret="$(echo "${raw:-}" | sed -E 's/^secret=([A-Z2-7]+).*$/\1/')"
    fi
    # Fallback: derive from shared_secret if needed
    local derived=""
    if [[ -z "$secret" && -n "${shared_secret:-}" ]]; then
      derived="$(b64_to_base32 "$shared_secret" || true)"
      [[ -n "$derived" ]] && secret="$derived"
    fi

    rm -f "$clean"

    if [[ -n "$secret" || -n "${shared_secret:-}" || -n "${identity_secret:-}" || -n "${uri:-}" ]]; then
      found=$((found+1))
      echo
      ok "Found Steamguard file: $f"
      [[ -n "${account_name:-}" ]]    && echo "account_name:       $account_name"
      [[ -n "${steamid:-}" ]]         && echo "steamid:            $steamid"
      [[ -n "${secret:-}" ]]          && echo "secret (TOTP):      $secret"
      [[ -n "${uri:-}" ]]             && echo "uri (from file):    $uri"
      [[ -n "${shared_secret:-}" ]]   && echo "shared_secret:      $shared_secret"
      [[ -n "${identity_secret:-}" ]] && echo "identity_secret:     $identity_secret"

      if [[ -n "${secret:-}" ]]; then
        local label="Steam"
        if [[ -n "${account_name:-}" ]]; then label="Steam:${account_name}"
        elif [[ -n "${steamid:-}" ]]; then label="Steam:${steamid}"; fi
        local label_enc; label_enc="$(url_encode_min "$label")"
        local otpauth="otpauth://totp/${label_enc}?secret=${secret}&issuer=Steam"
        local steam_uri="steam://${secret}"
        echo "steam-uri:         $steam_uri"
        echo "otpauth-universal: $otpauth"
      fi
    fi
  done

  if [[ $found -eq 0 ]]; then
    err "No secrets found. Inspect files under: $steam_f_dir"
    exit 1
  fi
}

# ========== FLOW STARTS HERE ==========

bold "Step 1) Download a portable Java runtime (Temurin JRE 11)"
info  "Downloading Temurin JRE 11 from Adoptium..."
curl -fsSL -o temurin-jre.tar.gz "$ADOPTIUM_JRE_URL"
tar -xzf temurin-jre.tar.gz
JAVA_BIN="$(find . -type d -path '*Contents/Home/bin' -maxdepth 5 | head -n1)"
if [[ -z "${JAVA_BIN:-}" ]]; then
  JAVA_BIN="$(find . -type f -name 'java' -perm +111 2>/dev/null | sed 's#/java$##' | head -n1)"
fi
[[ -n "${JAVA_BIN:-}" ]] || { err "Could not locate Java binary after extraction."; exit 1; }
ok "Java found: $JAVA_BIN"
"$JAVA_BIN/java" -version >/dev/null || { err "Java not runnable"; exit 1; }

bold "Step 2) Download Android Platform-Tools (adb)"
curl -fsSL -o platform-tools.zip "$PLATFORM_TOOLS_URL"
rm -rf platform-tools
unzip -q platform-tools.zip
ADB="${WORKDIR}/platform-tools/adb"
[[ -x "$ADB" ]] || { err "adb not found or not executable after extraction."; exit 1; }
ok "adb ready: $ADB"

bold "Step 3) Download Android Backup Extractor (abe.jar)"
curl -fsSL -o abe.jar "$ABE_URL"
[[ -s abe.jar ]] || { err "Failed to download abe.jar"; exit 1; }
ok "abe.jar downloaded."

bold "Before we continue..."
cat <<'NOTE'
On your PHONE:

  • Uninstall the current Steam app (DO NOT remove Steam Guard / authenticator).
  • Enable Developer Options and USB debugging.
  • Connect the phone to this Mac via USB.

We will verify ADB connectivity next.
NOTE
pause

bold "Step 4) Connect phone & authorize ADB"
"$ADB" kill-server >/dev/null 2>&1 || true
"$ADB" start-server >/dev/null 2>&1 || true
"$ADB" devices
info "If you see 'unauthorized', unlock the phone and accept the USB debugging prompt, then press Enter to re-check."
pause
DEVICES=$("$ADB" devices | awk '/\tdevice$/{print $1}')
[[ -n "$DEVICES" ]] || { err "No authorized devices found. Check cable and USB debugging."; exit 1; }
ok "Device(s) connected: $(echo "$DEVICES" | tr '\n' ' ')"

bold "Step 5) Legacy Steam 2.1.4 APK"
info  "Drop the APK beside this script or into: $WORKDIR"
find_apk_loop

bold "Step 6) Confirm you uninstalled Steam (but kept Steam Guard)"
confirm "Have you uninstalled the Steam app on your phone (without removing Steam Guard)?" \
  || { warn "Please uninstall it on the phone, then re-run."; exit 1; }

bold "Step 7) Install legacy Steam (with target-SDK bypass)"
info  "We will try: adb install --bypass-low-target-sdk-block <apk>"
info  "If it stalls/fails and your phone shows an 'older version' warning, tap:"
info  "   'More info' -> 'Install anyway' (unlock if needed), then retry here."
retries=0
until "$ADB" install --bypass-low-target-sdk-block "$APK_PATH"; do
  retries=$((retries+1))
  warn "Install attempt #$retries failed."
  if ! confirm "Did you tap 'More info' -> 'Install anyway' on the phone and want to retry?"; then
    err "Install did not complete. Cannot continue."
    exit 1
  fi
done
ok "Legacy Steam installed."

bold "Launching the legacy Steam app on your phone... (accept permissions)"
launch_app
info "(If you do not see it, launch Steam manually on your phone.)"
pause

bold "Step 8) Do the 'Please Help' recovery flow on the phone"
cat <<'FLOW'
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
FLOW
pause
confirm "Is the Steam app fully closed (swiped away)?" || { warn "Please fully close it and re-run."; exit 1; }

# Backup with retry & helper
backup_with_retry

bold "Step 10) Unpack backup.ab to backup.tar"
rm -f backup.tar
set +e
"$JAVA_BIN/java" -jar abe.jar unpack backup.ab backup.tar
rc=$?
set -e
if [[ $rc -ne 0 || ! -s backup.tar ]]; then
  err "Failed to unpack with abe.jar. If you set a backup password, we must supply it."
  if confirm "Did you set a backup password on the phone? Provide it now?"; then
    read -r -s -p "Backup password (input hidden): " BPPW; echo
    set +e
    "$JAVA_BIN/java" -jar abe.jar unpack backup.ab backup.tar "$BPPW"
    rc=$?
    set -e
    [[ $rc -eq 0 && -s backup.tar ]] || { err "Still failed to unpack. Wrong password or corrupted backup."; exit 1; }
  else
    exit 1
  fi
fi
BYTES=$(stat -f%z backup.tar 2>/dev/null || stat -c%s backup.tar 2>/dev/null || echo 0)
ok "Unpacked to backup.tar (${BYTES} bytes)"

extract_and_print_secrets

echo
bold "All done!"
info "You now have both 'steam-uri' and 'otpauth-universal' above for importing to your OTP app."

# -------- One-shot cleanup (everything) --------
if confirm "Clean up ALL artifacts and tools now? (backups + extracted files + JRE + platform-tools + abe.jar)"; then
  rm -rf \
    backup.ab backup.tar extracted \
    platform-tools platform-tools.zip \
    abe.jar temurin-jre.tar.gz jdk* jre*
  ok "Everything cleaned up."
else
  warn "Remember: backup files and extracted data are sensitive. Delete them when finished."
fi

ok "Script finished successfully."
ok "You may now update the Steam app to the latest verion through the Google Play Store."
