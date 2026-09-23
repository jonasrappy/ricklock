#!/bin/zsh
set -euo pipefail
source_dir="${0:A:h}"
app_dir="${RICKLOCK_APP_DIR:-$HOME/Applications/RickLock.app}"
config_dir="$HOME/Library/Application Support/RickLock"
if [[ ! -f "$source_dir/.env" ]]; then
  print -u2 "Missing $source_dir/.env. Copy .env.example to .env and set RICKLOCK_PASSWORD without the leading slash."
  exit 1
fi
for screenshot in desktop.png desktop-internal.png; do
  if [[ ! -f "$source_dir/$screenshot" ]]; then
    print -u2 "Missing $source_dir/$screenshot. Add your own decoy screenshot before building."
    exit 1
  fi
done
mkdir -p "$config_dir"
chmod 700 "$config_dir"
install -m 600 "$source_dir/.env" "$config_dir/.env"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
xcrun swift "$source_dir/make-icon.swift" "$source_dir/RickLock.iconset"
iconutil -c icns "$source_dir/RickLock.iconset" -o "$app_dir/Contents/Resources/RickLock.icns"
xcrun swiftc -O "$source_dir/main.swift" "$source_dir/BustedCamera.swift" "$source_dir/RickLockConfiguration.swift" "$source_dir/BackgroundMaintenance.swift" -o "$app_dir/Contents/MacOS/RickLock" -framework AppKit -framework WebKit -framework CryptoKit -framework AVFoundation -framework CoreImage
xcrun swiftc -O "$source_dir/AppMaintenance.swift" -o "$app_dir/Contents/Resources/.support" -framework AppKit
cp -X "$source_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp -X "$source_dir/prank.html" "$source_dir/rick.gif" "$source_dir/desktop.png" "$source_dir/desktop-internal.png" "$app_dir/Contents/Resources/"
codesign --force --sign - "$app_dir"
"$app_dir/Contents/MacOS/RickLock" --self-test
launcher_dir="${RICKLOCK_LAUNCHER_DIR:-$HOME/Applications/RickLock Launcher.app}"
mkdir -p "$launcher_dir/Contents/MacOS" "$launcher_dir/Contents/Resources"
xcrun swiftc -O "$source_dir/launcher.swift" -o "$launcher_dir/Contents/MacOS/RickLockLauncher" -framework AppKit
cp -X "$source_dir/Launcher-Info.plist" "$launcher_dir/Contents/Info.plist"
cp -X "$app_dir/Contents/Resources/RickLock.icns" "$launcher_dir/Contents/Resources/RickLock.icns"
codesign --force --sign - "$launcher_dir"
