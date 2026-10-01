# RickLock

A local macOS menu-bar prank with a pinned lock icon in the Dock. This is not a secure macOS lock.

## Using the app

- Click the Dock lock, or select **Activate prank** from the theater-mask menu-bar icon. Activation does not require a code.
- After three seconds, transparent input-blocking windows cover every display. Your current apps and menu bar remain visible underneath, with no screenshot, tint or blur. The Dock temporarily auto-hides so macOS can block normal app switching; its previous setting is restored on unlock.
- A small green dot beside the menu-bar icon means RickLock is armed. It disappears when you unlock. Hover over the icon to see "locked" or "ready".
- The first click, scroll, active gesture, media-key press, invalid key or shortcut reveals the Rick Astley GIF and the message, starts the camera, and displays one photo underneath **BUSTED** in the center. The photo then saves in the background to **Desktop/capture**. Pointer movement, key/button releases and unrelated system events are blocked quietly.
- The camera indicator remains visible. The camera shuts off after capture, on error, or when the prank is dismissed. There is no audio capture or saved video.
- Type `/` followed by your agreed code to dismiss. No Enter is required.
- Only a correct password prefix is accepted quietly. A wrong character, text without the leading slash, Enter, Tab or Escape immediately triggers the prank. Backspace can edit a valid prefix. Shift and Option can be used to type password characters. After a mistake, start again with `/` and type the full code to unlock.
- Normal minimize, Command-Q, and Command-Tab are blocked while the prank is active. There is no special emergency shortcut in the app.
- RickLock menu actions and normal menu/Dock quit requests cannot dismiss an armed prank. Key, mouse and gesture events delivered to RickLock are consumed while armed, including events outside its overlay windows and inside the Rickroll WebViews. Lost focus, changed Spaces and hidden overlays restore the overlay quietly without triggering the camera or resetting valid password input.
- Activation requires Accessibility access. A session-wide filtering event tap consumes keyboard, media-key (including volume), pointer, mouse-button, scroll and gesture events while armed. Only Shift/Option-assisted password input is accepted. The filter is removed immediately on unlock and never records or forwards typed text. Without permission or a working filter, RickLock refuses to arm.
- **Preview prank (camera off)** opens an ordinary, closable preview without taking a photo.
- **Test Busted camera…** opens an ordinary preview and takes one real photo.
- **Open Busted photos** opens the local photo archive.

Connecting or disconnecting a display, changing resolution, and waking from sleep preserve the active prank and unlock input. Overlays follow the current displays, including the built-in MacBook display after USB-C is unplugged. If Rick has already been revealed, replacement displays show the same prank and camera state without starting another photo.

## Camera permission and storage

macOS asks for camera permission before the first camera-enabled activation. It remembers the decision across normal app launches and restarts. A reset of privacy permissions, a different app identity, or a changed code signature after a rebuild can require approval again. Permission is never bypassed. If permission is denied, the camera is unavailable, or capture fails, the Rickroll continues and shows a camera-status message.

Photos are timestamped JPEGs stored only in:

`~/Desktop/capture`

Photos are displayed before background disk writing begins. A short fallback timer starts saving if the view closes or does not acknowledge display. Saving continues after unlocking, and a normal application quit waits for pending saves. Files are written atomically and synchronized before the status changes to SAVED. Saved files remain after shutdown or restart; an abrupt power loss or force quit before the write completes can still lose a pending photo. If saving fails, the image remains visible with an error message.

The archive is outside the app bundle, so rebuilding does not replace the photos. The folder uses owner-only access when created and saved photos use owner-only read/write permissions. RickLock does not upload photos or add them to the Photos library. If your Desktop is synced by iCloud or another service, that service may also sync this folder. macOS may request Desktop-folder access once. There is no automatic deletion; manage retained photos through **Open Busted photos**. Photos from earlier versions remain in `~/Library/Application Support/RickLock/Busted`; they are not moved or deleted. The camera is not pre-warmed while the transparent overlay is waiting for a click.

The capture session is configured while the overlay is armed, but starts running only on the first click or scroll. Capture begins immediately, in parallel with loading the Rickroll page. The first usable frame is encoded without a fixed exposure-settling delay. Near-black startup frames are skipped for at most 150 ms; lighting may still be less stable than after waiting longer. The photo is delivered without waiting for camera shutdown. Starting camera hardware is not instantaneous. A capture timeout or unlocking cancels capture; saving of an already captured and displayed photo continues. Each activation produces at most one photo, even with multiple displays or repeated clicks.

All UI copy, comments, and documentation are in English. The app uses a local GIF and keeps hashes of the unlock code and its valid prefixes instead of retaining the plaintext code. Its global input filter is active only while armed and requires macOS Accessibility permission. Other apps continue running. It does not change system sleep or lock settings and restores its presentation settings on dismissal.

System force quit, terminating the process, restart and some system shortcuts remain outside this app's control. Use the real macOS lock to protect data; RickLock is not a complete security boundary. Display changes and sleep do not dismiss RickLock; type your unlock code to dismiss it normally.

## Source and rebuilding

Create the local configuration before building:

```sh
cp .env.example .env
```

Set `RICKLOCK_PASSWORD` in `.env` without a leading slash. For example, `RICKLOCK_PASSWORD=change-me` is unlocked by typing `/change-me`. The slash is part of the unlock gesture and is never stored in `.env`.

`.env` is ignored by Git. Commit `.env.example`, but never commit `.env`. The build copies `.env` with owner-only permissions to `~/Library/Application Support/RickLock/.env`; the app reads that file when each prank is activated and keeps hashes of the code and its prefixes in memory. The secret is not compiled into Swift or copied into the app bundle. Re-run `./build.sh` after changing the source `.env`.

The old desktop screenshot assets have been removed. Building does not require desktop screenshots.

- `main.swift`: menu-bar app, overlay lifecycle, camera UI, and local unlock handling.
- `RickLockConfiguration.swift`: strict `.env` loading for the unlock password.
- `ExclusiveInput.swift`: temporary session-wide input suppression while armed.
- `BustedCamera.swift`: one-shot camera capture and private local JPEG storage.
- `prank.html`: offline Rickroll, centered BUSTED card, and click reactions.
- `make-icon.swift`: lock icon generated using native drawing.
- `build.sh`: compiles and locally ad-hoc signs the apps.
- `launcher.swift`: optional launcher; the pinned Dock shortcut can point directly to `RickLock.app`.

Close RickLock before running `./build.sh`. The default output is `~/Applications/RickLock.app`; set `RICKLOCK_APP_DIR` and `RICKLOCK_LAUNCHER_DIR` to override the app locations. Open `~/Applications/RickLock.app` afterward. On a fresh process, `--demo` previews without a camera, `--camera-demo` tests one photo, and `--idle` starts only the menu-bar icon. `--self-test` checks the unlock parser without starting the UI or camera.

GIF source: https://media.giphy.com/media/Vuw9m5wXviFIQ/giphy.gif

`--overlay-self-test` checks transparent input handling and simulated display disconnect, reconnect, resize and revealed-state preservation without showing overlay windows or using the camera. `--overlay-ui-test` runs a camera-free transparent overlay test, unlocked with `/test-code`, and exits automatically after 45 seconds.

`--camera-speed-test` takes one real webcam photo and prints capture-to-JPEG latency and image dimensions without saving it. Add `--prepared` to measure capture after session configuration, as during a normal armed prank.

`--input-filter-check` checks whether macOS permits creating the input filter without blocking input. To grant access, enable RickLock in System Settings > Privacy & Security > Accessibility and restart the app. A changed ad-hoc signature after rebuilding may require granting access again. The camera-free `--overlay-ui-test` uses the same filter, `/test-code` to unlock, and a 45-second automatic exit.

Camera-permission reference: https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos
