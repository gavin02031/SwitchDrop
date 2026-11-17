# SwitchDrop ✨

An AirDrop-like local file sender for a **modded Nintendo Switch / Switch Lite** and an **iPhone**.

SwitchDrop is **not Apple AirDrop**. It uses its own QR pairing and authenticated HTTP uploads over the same Wi-Fi network. Nothing is sent to a cloud service, and no FTP or MTP setup is required.

## How it works

1. Open the SwitchDrop homebrew `.nro` on your Switch.
2. Connect your Switch and iPhone to the same Wi-Fi network. The Switch shows a QR code.
3. Open SwitchDrop on iPhone and tap **Scan Switch QR code**. Pairing is remembered.
4. Tap **Send files to Switch** and choose files from Files. Alternatively, tap **Share → SwitchDrop** in iOS apps where the share extension is supported.
5. Received files go to `sdmc:/switch/switchdrop/inbox/` on the Switch SD card.

Sending the same filename twice automatically creates `file (2).ext`, so existing files are preserved. Failed uploads remove their partial file. The Switch shows transfer progress and a completed file count. Press **+** to exit the Switch app.

## Installation

### Switch

Download `switchdrop.nro` from GitHub Actions (or Releases when tagged) and copy it to:

```
sdmc:/switch/switchdrop/switchdrop.nro
```

Launch it through the Homebrew Menu. For reliable networking, launch Homebrew Menu with full application memory (hold **R** while starting a game) if Album/applet mode causes issues. The Switch must have working Wi-Fi access.

### iPhone

Download `SwitchDrop-unsigned.ipa` from GitHub Actions or Releases, then **sign it** with your normal iOS sideloading app before installing it. An unsigned IPA cannot be installed directly. The iOS app requests camera and local-network permissions for QR scanning and transfers.

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
- Incoming files are stored in a dedicated inbox, not automatically installed or executed. Sending game files does **not** install games.
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

Initial source implementation (v0.1). The portable receiver has a local Linux smoke test. **An actual NRO/IPA build and on-device pairing test are still required** before calling this a working public release.

© 2026 Gavin Marler and contributors. MIT licensed. The QR encoder retains the original Project Nayuki MIT copyright notice.
