#!/usr/bin/env bash
set -euo pipefail

resource_root="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
archive="${BUILT_PRODUCTS_DIR}/sandboxark-localizations.tar"
bundle_dir="${DERIVED_FILE_DIR}/sandboxark.bundle"

rm -rf "$bundle_dir"
rm -f "$archive"
mkdir -p "$bundle_dir"

cat > "$bundle_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>com.moraxyc.sandboxark.localization</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>SandboxArk</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
</dict>
</plist>
PLIST

shopt -s nullglob
localization_dirs=()
for localization_dir in "$resource_root"/*.lproj; do
	if [[ ! -f "$localization_dir/Localizable.strings" && ! -f "$localization_dir/Localizable.stringsdict" ]]; then
		continue
	fi
	name="${localization_dir##*/}"
	mkdir -p "$bundle_dir/$name"
	if [[ -f "$localization_dir/Localizable.strings" ]]; then
		cp "$localization_dir/Localizable.strings" "$bundle_dir/$name/Localizable.strings"
	fi
	if [[ -f "$localization_dir/Localizable.stringsdict" ]]; then
		cp "$localization_dir/Localizable.stringsdict" "$bundle_dir/$name/Localizable.stringsdict"
	fi
	localization_dirs+=("$name")
done

if [[ ${#localization_dirs[@]} -eq 0 ]]; then
	printf 'No compiled Localizable strings found in %s\n' "$resource_root" >&2
	exit 1
fi

entries=(Info.plist "${localization_dirs[@]}")
/usr/bin/tar --format=ustar -cf "$archive" -C "$bundle_dir" "${entries[@]}"
