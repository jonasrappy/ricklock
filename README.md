# RickLock

A local macOS menu-bar prank with a pinned lock icon in the Dock. This is not a secure macOS lock.

## Using the app

- Click the Dock lock, or select **Activate prank** from the theater-mask menu-bar icon. Activation does not require a code.
- After three seconds, decoy screenshots cover every display.
- The first click or scroll reveals the Rick Astley GIF and the message, starts the camera, and displays one photo underneath **BUSTED** in the center. The photo then saves in the background to **Desktop/capture**.
- The camera indicator remains visible. The camera shuts off after capture, on error, or when the prank is dismissed. There is no audio capture or saved video.
- Type `/` followed by your agreed code to dismiss. No Enter is required.
- Normal minimize, Command-Q, and Command-Tab are blocked while the prank is active. There is no special emergency shortcut in the app.
- **Preview prank (camera off)** opens an ordinary, closable preview without taking a photo.
- **Test Busted camera…** opens an ordinary preview and takes one real photo.
- **Open Busted photos** opens the local photo archive.

The built-in MacBook display uses `desktop-internal.png`; external displays use `desktop.png`. Images cover their displays proportionally, cropping any aspect-ratio mismatch instead of stretching. The built-in image also works when no external display is connected.

## Camera permission and storage

macOS asks for camera permission before the first camera-enabled activation. It remembers the decision across normal app launches and restarts. A reset of privacy permissions, a different app identity, or a changed code signature after a rebuild can require approval again. Permission is never bypassed. If permission is denied, the camera is unavailable, or capture fails, the Rickroll continues and shows a camera-status message.

Photos are timestamped JPEGs stored only in:

`~/Desktop/capture`

Photos are displayed before background disk writing begins. A short fallback timer starts saving if the view closes or does not acknowledge display. Saving continues after unlocking, and a normal application quit waits for pending saves. Files are written atomically and synchronized before the status changes to SAVED. Saved files remain after shutdown or restart; an abrupt power loss or force quit before the write completes can still lose a pending photo. If saving fails, the image remains visible with an error message.

The archive is outside the app bundle, so rebuilding does not replace the photos. The folder uses owner-only access when created and saved photos use owner-only read/write permissions. RickLock does not upload photos or add them to the Photos library. If your Desktop is synced by iCloud or another service, that service may also sync this folder. macOS may request Desktop-folder access once. There is no automatic deletion; manage retained photos through **Open Busted photos**. Photos from earlier versions remain in `~/Library/Application Support/RickLock/Busted`; they are not moved or deleted. The camera is not pre-warmed while the decoy desktop is waiting for a click.

The camera briefly settles its exposure before returning a single frame. Starting camera hardware is not instantaneous. A capture timeout or unlocking cancels capture; saving of an already captured and displayed photo continues. Each activation produces at most one photo, even with multiple displays or repeated clicks.

All UI copy, comments, and documentation are in English. The supplied desktop screenshots are preserved as original user assets. The app uses local GIF and image files, stores the unlock code as a hash, and consumes keyboard events only in its own prank windows. Other apps continue running. It does not change system sleep or lock settings and restores its presentation settings on dismissal.

System force quit and restart remain available. Use the real macOS lock to protect data. RickLock dismisses itself when the physical display arrangement changes or the computer goes to sleep.

## Source and rebuilding

Create the local configuration before building:

```sh
cp .env.example .env
```

Set `RICKLOCK_PASSWORD` in `.env` without a leading slash. For example, `RICKLOCK_PASSWORD=change-me` is unlocked by typing `/change-me`. The slash is part of the unlock gesture and is never stored in `.env`.

`.env` is ignored by Git. Commit `.env.example`, but never commit `.env`. The build copies `.env` with owner-only permissions to `~/Library/Application Support/RickLock/.env`; the app reads that file when each prank is activated and keeps only its hash in memory. The secret is not compiled into Swift or copied into the app bundle. Re-run `./build.sh` after changing the source `.env`.

The repository includes `desktop.png` for external displays and `desktop-internal.png` for the built-in MacBook display. Replace them with your own decoy screenshots before building if desired.

- `main.swift`: menu-bar app, overlay lifecycle, camera UI, and local unlock handling.
- `RickLockConfiguration.swift`: strict `.env` loading for the unlock password.
- `BustedCamera.swift`: one-shot camera capture and private local JPEG storage.
- `prank.html`: offline Rickroll, centered BUSTED card, and click reactions.
- `make-icon.swift`: lock icon generated using native drawing.
- `build.sh`: compiles and locally ad-hoc signs the apps.
- `launcher.swift`: optional launcher; the pinned Dock shortcut can point directly to `RickLock.app`.

Close RickLock before running `./build.sh`. The default output is `~/Applications/RickLock.app`; set `RICKLOCK_APP_DIR` and `RICKLOCK_LAUNCHER_DIR` to override the app locations. Open `~/Applications/RickLock.app` afterward. On a fresh process, `--demo` previews without a camera, `--camera-demo` tests one photo, and `--idle` starts only the menu-bar icon. `--self-test` checks the unlock parser without starting the UI or camera.

GIF source: https://media.giphy.com/media/Vuw9m5wXviFIQ/giphy.gif

Desktop assets: replace `desktop.png` and `desktop-internal.png` with your own external-display and built-in-display decoy screenshots before building.

Camera-permission reference: https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos
