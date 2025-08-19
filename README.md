# Steam Guard Extractor (macOS)

**Status:** Verified working on **19 Aug 2025**

A dead-simple, user-friendly CLI that extracts your **Steam Guard** secret from an Android backup using a temporary legacy Steam APK. It:

- Downloads a portable **Temurin JRE 11** (local to the working folder).
- Downloads **Android Platform-Tools** (ADB) from Google.
- Downloads a known-working **Android Backup Extractor (abe.jar)**.
- Walks you step-by-step (with “press Enter to continue” pauses), verifies each step, and fails fast with helpful messages.
- Prints **both** import formats when done:
  - `steam://<SECRET>`
  - `otpauth://totp/<Label>?secret=<SECRET>&issuer=Steam`

> ⚠️ Your secret is as sensitive as a password. Keep it private, and delete backups when you’re done.

---

## Quick start (macOS)

```bash
# 1) Get the script into an empty folder, then:
chmod +x steam-guard-extractor-macos.sh
./steam-guard-extractor-macos.sh
```

During the run, the script will ask you to place the legacy APK:

- **Download page** (one click to the right release):  
  https://www.apkmirror.com/apk/valve-corporation/steam/steam-2-1-4-release/steam-2-1-4-android-apk-download/
- Put the APK file either **beside the script** or in the created folder:  
  `./steam_guard_extractor_work/`

The script auto-detects the APK (auto-selects if only one is present), installs it with the proper bypass flag, can **launch/kill** the app via ADB to help you hit the right on-device screens, creates the Android backup, unpacks it, and locates your Steamguard file(s).

---

## What you’ll see at the end

You’ll get both forms printed:

```
steam-uri:         steam://OIXDOCOM6O3CMQJXTRHX6YTZMBH7C4NW
otpauth-universal: otpauth://totp/Steam:YOUR_USERNAME?secret=OIXDOCOM6O3CMQJXTRHX6YTZMBH7C4NW&issuer=Steam
```

Either can be used to add the token to most OTP apps.  
If the backup doesn’t contain a direct `secret=...`, the script derives a valid Base32 secret from `shared_secret` so you still get importable strings.

---

## What the script does (high level)

1. **Sets up tools locally** (JRE, ADB, abe.jar) — no system installs required.
2. **Verifies ADB** connectivity and that your phone is authorized.
3. **Installs** the legacy Steam 2.1.4 APK (guides you if Android warns “older version” → **More info → Install anyway**).
4. **Guides** you through the app’s **“Please Help → Use this device → OK!”** flow, then has you **force-close** the app.
5. **Creates the backup** (`adb backup`) with a helper loop (can auto-launch and force-stop Steam between tries).
6. **Unpacks** the backup with `abe.jar` and **extracts** secrets from `Steamguard-*`.
7. **Prints** `steam://<SECRET>` and `otpauth://...` and offers **one-shot cleanup** (backups + tools).

---

## Understanding the `otpauth://` URL

The script prints a standard **otpauth** URL that most OTP apps understand:

```
otpauth://totp/<Label>?secret=<SECRET>&issuer=Steam
```

- **`totp`** — the algorithm type (time-based one-time passwords).
- **`<Label>`** — what your app shows as the account name.  
  The script uses `Steam:YOUR_USERNAME` (or `Steam:STEAMID` if username isn’t present).
- **`secret`** — your Base32-encoded TOTP seed. This is the critical value to keep safe.
- **`issuer`** — a display hint for the app (here, `Steam`).

> Steam tokens use **5 characters** per code. Many OTP apps support custom digit lengths; the URL some apps parse may also include `&digits=5` (not strictly required for apps that default to Steam behavior). The script prints a minimal URL for broad compatibility.

---

## Add to FreeOTP+ (Android)

In **FreeOTP+**:

- **Add Token**
- **Issuer**: `Steam`
- **Account**: `YOUR_USERNAME` (or whatever you prefer to see)
- **Secret**: paste the Base32 secret (the part after `secret=` in the printed URL)
- **Type**: **TOTP**
- **Digits**: **5**

(If FreeOTP+ offers additional options, leave **Algorithm** = SHA-1 and **Period** = 30s, which are standard for Steam.)

---

## Typical pitfalls & tips

- **ADB shows `unauthorized`**: unlock the phone, accept the “Allow USB debugging?” prompt, then continue.
- **Install blocked / older app warning**: on the phone, tap **More info → Install anyway**, then retry in the script.
- **Backup is ~1KB**: you didn’t fully close the legacy Steam app — **force-close** it (swipe away) and try again. The script can **kill & relaunch** the app to help you repeat the on-device steps.
- **“No secrets found”**: the script strips any NUL bytes and parses robustly. If it still can’t find anything, open `extracted/apps/com.valvesoftware.android.steam.community/f/` and look for files named `Steamguard-*`.

---

## Security & cleanup

When prompted, choose the **one-shot cleanup** to remove:

- `backup.ab`, `backup.tar`, `extracted/`
- Downloaded tools: `platform-tools`, `abe.jar`, `temurin-jre` archive & folder

You can always re-run the script later to recreate the environment.

---

## Compatibility notes

- macOS on **Intel** and **Apple Silicon** are both supported (script auto-detects and fetches the correct JRE).
- Most OTP apps accept either the `steam://<SECRET>` form or the `otpauth://` form; if your app refuses 5-digit tokens, pick one that supports them (e.g., FreeOTP+, Aegis, Bitwarden with Steam support, etc.).

---

## Credits

- Original community guide that inspired this tool:  
  https://www.reddit.com/r/Bitwarden/comments/1auercm/updated_feb_2024_guide_extracting_steam_guard/

---

## Disclaimer

Use at your own risk. This tool manipulates your authenticator data locally and never transmits it, but you’re responsible for safeguarding backups and secrets and for complying with any applicable terms of service.
