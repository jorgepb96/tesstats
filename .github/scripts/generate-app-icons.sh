#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
master_icon="$repo_dir/docs/app-icon-master.png"
ios_icon="$repo_dir/Tesstats/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"
mac_dir="$repo_dir/Tesstats/Resources/Assets.xcassets/AppIcon.appiconset"
watch_icon="$repo_dir/TesstatsWatch/Assets.xcassets/AppIcon.appiconset/WatchAppIcon1024.png"

if [ ! -f "$master_icon" ]; then
  echo "Missing app icon master: $master_icon" >&2
  exit 1
fi

# Keep the approved generated artwork as the single source of truth, then
# derive every platform size from the same opaque square master.
sips --resampleHeightWidth 1024 1024 "$master_icon" --out "$ios_icon" >/dev/null

cp "$ios_icon" "$mac_dir/mac-1024.png"
cp "$ios_icon" "$watch_icon"

for size in 512 256 128 64 32 16; do
  sips --resampleHeightWidth "$size" "$size" "$ios_icon" \
    --out "$mac_dir/mac-$size.png" >/dev/null
done

echo "Generated iOS, macOS, and watchOS app icons from docs/app-icon-master.png."
