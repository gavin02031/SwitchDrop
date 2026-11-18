# SwitchDrop ✨

An AirDrop-like local file sender for a **modded Nintendo Switch / Switch Lite** and an **iPhone**.

SwitchDrop is **not Apple AirDrop**. It uses its own QR pairing and authenticated HTTP uploads over the same Wi-Fi network. Nothing is sent to a cloud service, and no FTP or MTP setup is required.

## How it works

1. Open the SwitchDrop homebrew `.nro` on your Switch.
2. Connect your Switch and iPhone to the same Wi-Fi network. The Switch shows a QR code.
3. Open SwitchDrop on iPhone and tap **Scan Switch QR code**. Pairing is remembered.
4. Your iPhone opens the **SD Card** browser. Tap folders (for example `switch`, `atmosphere`, or `Music`) to explore their contents. Use the breadcrumb to go back to any parent folder.
5. Tap the compact **Send file** button at the bottom and select one file in iOS Files. SwitchDrop sends to the directory currently open on your phone — including the SD card root if you choose it. Repeat for additional files.
6. Tap the **↓ download arrow at the right edge of any file row** (or tap its filename and choose **Download to iPhone**). SwitchDrop saves it into **On My iPhone → SwitchDrop → Downloads** and opens the iOS share sheet so you can save or send a copy anywhere.
7. Open the new **Logs** tab to scan common homebrew, Atmosphère crash-report, and error-report directories. Tap a result to download it or preview up to the first 64 KB of readable text. The scan is bounded (maximum 80 folders) and does not search Nintendo game content.
8. **Share → SwitchDrop** from other iOS apps sends to the last destination chosen in the main app, when the Share extension is supported by your signing method.

Sending the same filename twice automatically creates `file (2).ext`, so existing files are preserved. Failed uploads remove their partial file. The Switch shows transfer progress and a completed file count. Press **+** to exit the Switch app. Listings are paged (120 items per page) so very large folders can be browsed using **Load more files**.

### Liquid Glass redesign

- On **iOS 26+**, the app uses SwiftUI's actual Liquid Glass material for rounded cards and controls. On iOS 16–25 it falls back to translucent system materials.
- The **Switch** uses a matching pastel, translucent SDL design while keeping the pairing QR code fully opaque for scanning.
- The original SwitchDrop icon was remastered with iridescent lilac and mint glass highlights; the original artwork remains in the source tree.
- **Quick paths** jump to the SD root, `/switch` (homebrew) and SwitchDrop's inbox. Search filters the current *loaded* folder page; **Load more files** fetches additional entries. Sorting can show the largest files first.
- **Recent transfers** shows a local history of the last 30 successful uploads and downloads (filename, destination, size, date). Only metadata is stored on the iPhone; no files or history are uploaded to cloud services.
- **Compact file-first layout:** the connected banner, tabs, shortcuts, breadcrumbs, search, and bottom upload bar take less vertical space so the SD-card listing stays in focus. Individual file and log rows have a dedicated 44-point download arrow.

### Two-way transfer and Log Manager (next beta)

- **Download existing Switch files:** open any SD folder and tap the download arrow at the end of the file row. The app streams the response to a temporary file, then moves it into its visible `Documents/Downloads` folder, preserving existing downloads by adding a numeric suffix to name collisions. If the Switch receiver is outdated or the transfer fails, the iPhone displays a specific error alert.
- **Save / share:** iOS immediately presents the system share sheet after a download, and previously saved files can be reopened from **⋯ → Saved downloads**. The files remain in the iPhone app's Documents directory unless you remove them manually.
- **Quick log scan:** the **Logs** tab looks in common `atmosphere`, `/switch`, `/config`, and `/logs` subdirectories for log-like filenames. It skips heavy patch/game content and may miss logs in unusual folders. Browse those manually from **Files**.
- **Safe text previews:** `/preview` returns at most 64 KB (never the entire huge report), and `/download` streams up to 16 GiB per file. Both endpoints use the same QR token and SD-root path restrictions as `/browse` and `/upload`. No internal NAND access or remote uploads of logs are involved.
- New Switch receivers advertise `download` and `preview` in `/health`. Older QR-paired receivers still work for uploads, but you must install the updated NRO to enable downloads.

## Installation

### Switch

Download `switchdrop.nro` from GitHub Actions (or Releases when tagged) and copy it to:

```
sdmc:/switch/switchdrop/switchdrop.nro
```

Launch it through the Homebrew Menu. For reliable networking, launch Homebrew Menu with full application memory (hold **R** while starting a game) if Album/applet mode causes issues. The Switch must have working Wi-Fi access.

### iPhone

Download `SwitchDrop-unsigned.ipa` from GitHub Actions or Releases, then **sign it** with your normal iOS sideloading app before installing it. An unsigned IPA cannot be installed directly. The iOS app requests camera and local-network permissions for QR scanning and transfers.

The **Send file** picker imports a private local copy before uploading, so the transfer does not depend on an open-in-place iCloud URL. Tap one file to import and send it directly; select another file afterward for additional transfers. This avoids the iOS multi-select picker’s **Open** confirmation button, which sometimes fails to respond. If an iCloud Drive file is not available, use Files → long-press the file → **Download Now**, or copy it into **On My iPhone** before selecting it.

**Important for downloads:** update **both** `SwitchDrop-unsigned.ipa` on your iPhone and `switchdrop.nro` on your Switch from the **same new Actions run**. Older receiver builds only supported uploads and will not respond to download requests. If the download arrow reports an outdated receiver, replace `sdmc:/switch/switchdrop/switchdrop.nro`, reopen the homebrew app, and rescan its QR code.

The Share Sheet extension uses a shared App Group (`group.com.gavin02031.switchdrop`). Your signing method must preserve/provision the matching App Group entitlement for both app and extension. If your sideloading signer does not support App Groups, use **Send a file here** inside the main iPhone app instead. This limitation is due to iOS provisioning, not the Switch.

**Downloading a log:** leave SwitchDrop open on the Switch → iPhone **Logs** → **Scan logs** (or open it for automatic scan) → tap a result → **Preview log** or **Download log to iPhone**. For Morrow or another app that writes logs to a custom directory, browse that folder directly under **Files** and tap its log. Text previews are read-only. Some homebrew apps only write logs after crashing or when logging is enabled.

## Build it

Both outputs build in the same GitHub Actions workflow at `.github/workflows/build.yml`:

- **NRO:** devkitPro's devkitA64/libnx and `switch-sdl2` on Linux.
- **IPA:** XcodeGen and Xcode on GitHub's macOS runner. The generated IPA is unsigned and includes the Share Sheet extension.

Push to `main` or choose **Actions → Build SwitchDrop → Run workflow** to download the two build artifacts. Creating and pushing a tag named `v0.1.0` triggers a GitHub Release containing both files (after both jobs succeed).

To build locally:

```bash
# Linux with devkitPro and switch-sdl2 installed
make -C switch

# macOS with Xcode and xcodegen installed
cd ios
xcodegen generate
xcodebuild -project SwitchDrop.xcodeproj -scheme SwitchDrop \
  -destination 'generic/platform=iOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO build
```

Run the portable server tests on Linux:

```bash
cc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -pthread \
  switch/source/drop_server.c switch/tests/server_smoke.c \
  -o /tmp/switchdrop-smoke && /tmp/switchdrop-smoke
```

## Security and limitations

- Transfers are allowed only while the Switch homebrew app is running. The pairing key is stored in `sdmc:/switch/switchdrop/pairing.key`, so a paired iPhone remains linked after restarting SwitchDrop on the same Wi-Fi/IP. If the Switch receives a different local IP address, scan again to update it.
- The QR code contains a random secret; don't share screenshots of it with people you don't trust. To revoke *all* previous pairings, delete `pairing.key` on the SD card while SwitchDrop is closed; the next launch generates a new key.
- This is plain HTTP **within your local network**, authenticated with the QR secret but **not encrypted**. Only use a trusted Wi-Fi network. For public/hotel Wi-Fi, do not use SwitchDrop yet.
- Pairing is restricted to private IPv4 LAN addresses and TCP port `38470`; no external web service is involved.
- The iPhone browser exposes the **whole SD card (`sdmc:/`)**, including homebrew and Atmosphère directories, but deliberately excludes internal NAND/system partitions. Changing critical files on the SD card can still break your setup, so select destinations carefully and keep backups. SwitchDrop can read/download SD files but cannot browse or read internal system partitions.
- **Treat downloaded logs as private.** App logs and crash dumps can contain local paths, identifiers, session tokens, or other sensitive content. Review before sharing them publicly, and only use SwitchDrop on trusted Wi-Fi because its local HTTP traffic is not encrypted.
- Uploads go into your selected SD folder and are never automatically installed or executed. Existing files are never overwritten. Sending game files does **not** install games.
- The receiver rejects `..` traversal, symlink-based escapes, invalid names and destinations outside the SD card. The local protocol is now version 2: update **both** the iPhone and NRO apps together.
- Files up to 16 GiB are accepted by the protocol, but SD card filesystems such as FAT32 impose a ~4 GiB per-file limit. Large transfers may fail on FAT32. A partial transfer is removed on failure.
- iOS file selection, downloads, and the Share Sheet extension work in the foreground. Downloading folders as ZIP archives, background transfers, and Windows/Android clients are planned for later.

## Project structure

| Folder | Contents |
| --- | --- |
| `switch/source` | libnx/SDL2 app and streaming transfer server |
| `switch/vendor` | Nayuki MIT QR encoder (`qrcodegen.c`, `qrcodegen.h`) |
| `switch/tests` | Linux socket and filesystem smoke tests |
| `ios/SwitchDrop` | SwiftUI app, QR scanner, file picker |
| `ios/Shared` | Pairing, transfer, and shared App Group storage |
| `ios/ShareExtension` | Native iOS Share Sheet action |
| `.github/workflows` | Automatic NRO, unsigned IPA, and release builds |

## Status

The current source includes the Liquid Glass redesign, two-way transfers, log scanning/previews, quick destinations, local search and transfer history. The portable receiver's Linux smoke tests cover directory listing, uploads, downloads, previews, name collisions and traversal/symlink rejection. GitHub Actions compile both binaries. **QR pairing and SD browsing have been tested on a real iPhone and Switch Lite; the latest iOS file-picker fix, two-way transfers, log scans, and end-to-end upload still require retesting on the user's devices.**

© 2026 Gavin Marler and contributors. MIT licensed. The QR encoder retains the original Project Nayuki MIT copyright notice.
