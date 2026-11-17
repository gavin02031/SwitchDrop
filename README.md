# SwitchDrop ✨

An AirDrop-like local file sender for a **modded Nintendo Switch / Switch Lite** and an **iPhone**.

SwitchDrop is **not Apple AirDrop**. It uses its own QR pairing and authenticated HTTP uploads over the same Wi-Fi network. Nothing is sent to a cloud service, and no FTP or MTP setup is required.

## How it works

1. Open the SwitchDrop homebrew `.nro` on your Switch.
2. Connect your Switch and iPhone to the same Wi-Fi network. The Switch shows a QR code.
3. Open SwitchDrop on iPhone and tap **Scan Switch QR code**. Pairing is remembered.
4. Your iPhone opens the **SD Card** browser. Tap folders (for example `switch`, `atmosphere`, or `Music`) to explore their contents. Use the breadcrumb to go back to any parent folder.
5. Tap **Send files here** and select files in iOS Files. SwitchDrop sends to the directory currently open on your phone — including the SD card root if you choose it.
6. **Share → SwitchDrop** from other iOS apps sends to the last destination chosen in the main app, when the Share extension is supported by your signing method.

Sending the same filename twice automatically creates `file (2).ext`, so existing files are preserved. Failed uploads remove their partial file. The Switch shows transfer progress and a completed file count. Press **+** to exit the Switch app. Listings are paged (120 items per page) so very large folders can be browsed using **Load more files**.

## Installation

### Switch

Download `switchdrop.nro` from GitHub Actions (or Releases when tagged) and copy it to:

```
sdmc:/switch/switchdrop/switchdrop.nro
```

Launch it through the Homebrew Menu. For reliable networking, launch Homebrew Menu with full application memory (hold **R** while starting a game) if Album/applet mode causes issues. The Switch must have working Wi-Fi access.

### iPhone

Download `SwitchDrop-unsigned.ipa` from GitHub Actions or Releases, then **sign it** with your normal iOS sideloading app before installing it. An unsigned IPA cannot be installed directly. The iOS app requests camera and local-network permissions for QR scanning and transfers.

The **Send files here** picker imports a private local copy before uploading, so the transfer does not depend on an open-in-place iCloud URL. If an iCloud Drive file still shows a cloud-download badge and **Open** does nothing, use Files → long-press the file → **Download Now**, or copy it into **On My iPhone** before selecting it.

The Share Sheet extension uses a shared App Group (`group.com.gavin02031.switchdrop`). Your signing method must preserve/provision the matching App Group entitlement for both app and extension. If your sideloading signer does not support App Groups, use **Send files to Switch** inside the main iPhone app instead. This limitation is due to iOS provisioning, not the Switch.

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
- The iPhone browser exposes the **whole SD card (`sdmc:/`)**, including homebrew and Atmosphère directories, but deliberately excludes internal NAND/system partitions. Changing critical files on the SD card can still break your setup, so select destinations carefully and keep backups. SwitchDrop only lists filenames, folder names, types and sizes; it does not download your existing files.
- Uploads go into your selected SD folder and are never automatically installed or executed. Existing files are never overwritten. Sending game files does **not** install games.
- The receiver rejects `..` traversal, symlink-based escapes, invalid names and destinations outside the SD card. The local protocol is now version 2: update **both** the iPhone and NRO apps together.
- Files up to 16 GiB are accepted by the protocol, but SD card filesystems such as FAT32 impose a ~4 GiB per-file limit. Large transfers may fail on FAT32. A partial transfer is removed on failure.
- iOS file selection and the Share Sheet extension work in the foreground. Background transfers and Windows/Android clients are planned for later.

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

Beta 2 source implements SD-card browsing, selectable upload destinations and the refreshed pastel UI on both apps. The portable receiver's Linux smoke tests cover directory listing, uploads, name collisions and traversal/symlink rejection. GitHub Actions compile both binaries. **Hardware pairing and end-to-end transfers remain unverified** until tested on a real Switch and iPhone.

© 2026 Gavin Marler and contributors. MIT licensed. The QR encoder retains the original Project Nayuki MIT copyright notice.
