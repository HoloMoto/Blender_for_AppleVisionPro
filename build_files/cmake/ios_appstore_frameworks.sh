#!/bin/sh
# Rewrite App Store–illegal Mach-O under Assets/ into Frameworks/*.framework.
# Python MH_BUNDLE (.so) cannot be framework executables (ITMS-90124); gzip them
# for runtime extraction instead.
# Usage: ios_appstore_frameworks.sh <Blender.app>
set -e
BUNDLE="${1:?Blender.app path required}"
BUNDLE="$(cd "$BUNDLE" && pwd)"
ASSETS="$BUNDLE/Assets"
FW_DIR="$BUNDLE/Frameworks"
LIB_DIR="$ASSETS/lib"
ID="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -z "$ID" ]; then
  ID="-"
fi
# Match Blender.app Info.plist MinimumOSVersion when possible.
MIN_OS="26.0"
if [ -f "$BUNDLE/Info.plist" ]; then
  _mos=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$BUNDLE/Info.plist" 2>/dev/null || true)
  if [ -n "$_mos" ]; then
    MIN_OS="$_mos"
  fi
fi

mkdir -p "$FW_DIR"

sanitize_bundle_id() {
  # CFBundleIdentifier may only contain [A-Za-z0-9.-]
  printf '%s' "$1" | /usr/bin/sed -E 's/[^A-Za-z0-9.-]/-/g; s/-+/-/g; s/^\.+//; s/\.+$//; s/^\-+//; s/\-+$//'
}

plist_for() {
  # $1 = framework binary name (CFBundleExecutable)
  # $2 = full CFBundleIdentifier
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$1</string>
	<key>CFBundleIdentifier</key>
	<string>$2</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$1</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>XROS</string>
	</array>
	<key>MinimumOSVersion</key>
	<string>${MIN_OS}</string>
</dict>
</plist>
EOF
}

macho_filetype() {
  # Prints DYLIB, BUNDLE, EXECUTE, or UNKNOWN
  desc=$(/usr/bin/file -b "$1" 2>/dev/null || true)
  case "$desc" in
    *"dynamically linked shared library"*) echo DYLIB ;;
    *"bundle"*) echo BUNDLE ;;
    *"executable"*) echo EXECUTE ;;
    *) echo UNKNOWN ;;
  esac
}


wrap_dylib() {
  # $1 = source MH_DYLIB path, $2 = framework base name (no .framework)
  src="$1"
  name="$2"
  dest_dir="$FW_DIR/${name}.framework"
  dest_bin="$dest_dir/$name"
  leaf_id=$(sanitize_bundle_id "$name")
  [ -z "$leaf_id" ] && leaf_id="lib"
  full_id="org.blenderfoundation.embedded.${leaf_id}"
  mkdir -p "$dest_dir"
  /bin/cp -f "$src" "$dest_bin"
  chmod +x "$dest_bin"
  plist_for "$name" "$full_id" >"$dest_dir/Info.plist"
  /usr/bin/install_name_tool -id "@rpath/${name}.framework/${name}" "$dest_bin" 2>/dev/null || true
  # Do NOT preserve old identifier; it must match CFBundleIdentifier (ITMS-90334).
  /usr/bin/codesign --force --sign "$ID" --identifier "$full_id" --timestamp=none "$dest_dir" || exit 1
}

# Remove any previously generated frameworks (rebuild-safe).
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR"

# --- Bundled dylibs: Assets/lib/*.dylib -> Frameworks/<name>.framework ---
if [ -d "$LIB_DIR" ]; then
  for dylib in "$LIB_DIR"/*.dylib; do
    [ -e "$dylib" ] || continue
    base="$(basename "$dylib" .dylib)"
    ft=$(macho_filetype "$dylib")
    case "$ft" in
      DYLIB)
        wrap_dylib "$dylib" "$base"
        rm -f "$dylib"
        ;;
      *)
        echo "ios_appstore_frameworks: skip non-DYLIB $dylib ($ft)" >&2
        rm -f "$dylib"
        ;;
    esac
  done
fi

# Rewrite @rpath/libFoo.dylib -> @rpath/libFoo.framework/libFoo on Blender + frameworks.
rewrite_deps() {
  bin="$1"
  [ -f "$bin" ] || return 0
  deps="$(/usr/bin/otool -L "$bin" 2>/dev/null | /usr/bin/awk '/@rpath\/.*\.dylib/ {print $1}')"
  for dep in $deps; do
    case "$dep" in
      @rpath/*.dylib)
        leaf="${dep#@rpath/}"
        leaf="${leaf%.dylib}"
        new="@rpath/${leaf}.framework/${leaf}"
        if [ "$dep" != "$new" ]; then
          /usr/bin/install_name_tool -change "$dep" "$new" "$bin" 2>/dev/null || true
        fi
        ;;
    esac
  done
}

if [ -x "$BUNDLE/Blender" ]; then
  if /usr/bin/otool -l "$BUNDLE/Blender" | /usr/bin/grep -q '@loader_path/Assets/lib'; then
    /usr/bin/install_name_tool -rpath '@loader_path/Assets/lib' '@loader_path/Frameworks' "$BUNDLE/Blender" 2>/dev/null || \
      /usr/bin/install_name_tool -add_rpath '@loader_path/Frameworks' "$BUNDLE/Blender" 2>/dev/null || true
  else
    /usr/bin/otool -l "$BUNDLE/Blender" | /usr/bin/grep -q '@loader_path/Frameworks' || \
      /usr/bin/install_name_tool -add_rpath '@loader_path/Frameworks' "$BUNDLE/Blender" 2>/dev/null || true
  fi
  rewrite_deps "$BUNDLE/Blender"
fi

for fwbin in "$FW_DIR"/*.framework/*; do
  [ -f "$fwbin" ] || continue
  case "$fwbin" in
    */Info.plist) continue ;;
  esac
  rewrite_deps "$fwbin"
  # Re-sign after install_name_tool (invalidates signature).
  fwdir=$(dirname "$fwbin")
  name=$(basename "$fwbin")
  leaf_id=$(sanitize_bundle_id "$name")
  [ -z "$leaf_id" ] && leaf_id="lib"
  full_id="org.blenderfoundation.embedded.${leaf_id}"
  /usr/bin/codesign --force --sign "$ID" --identifier "$full_id" --timestamp=none "$fwdir" || exit 1
done

# --- Python: remove interpreter; gzip MH_BUNDLE extensions (not frameworks) ---
find "$ASSETS" -path '*/python/bin/*' -type f \( -perm +111 -o -name 'python*' \) -delete 2>/dev/null || true
find "$ASSETS" -type d -path '*/python/bin' -empty -delete 2>/dev/null || true

# Drop numpy test extension modules (not needed at runtime).
find "$ASSETS" -path '*/site-packages/numpy/*' \( -name '*_tests*.so' -o -name '*_test*.so' \) -delete 2>/dev/null || true

# Remove leftover invalid python frameworks from older packaging attempts.
find "$FW_DIR" -maxdepth 1 -type d -name '*.cpython-*-darwin.framework' -exec rm -rf {} + 2>/dev/null || true

find "$ASSETS" \( -name '*.so' -o -name '*.dylib' \) -type f 2>/dev/null | while read -r so; do
  ft=$(macho_filetype "$so")
  case "$ft" in
    BUNDLE)
      # App Store rejects MH_BUNDLE as framework executables (ITMS-90124).
      # Store gzip so the bundle has no raw Mach-O under Assets/.
      /usr/bin/gzip -nf "$so"
      # gzip renames to .so.gz / .dylib.gz
      ;;
    DYLIB)
      base="$(basename "$so")"
      case "$base" in
        *.dylib) name="${base%.dylib}" ;;
        *.so) name="${base%.so}" ;;
        *) name="$base" ;;
      esac
      wrap_dylib "$so" "$name"
      rm -f "$so"
      ;;
    *)
      echo "ios_appstore_frameworks: removing unsupported Mach-O $so ($ft)" >&2
      rm -f "$so"
      ;;
  esac
done

# Final sweep: no raw Mach-O under Assets.
find "$ASSETS" \( -name '*.so' -o -name '*.dylib' -o -name '*.o' -o -name '*.a' \) -type f -delete 2>/dev/null || true

echo "ios_appstore_frameworks: staged $(ls -1 "$FW_DIR" 2>/dev/null | wc -l | tr -d ' ') dylib frameworks; python extensions gzipped"
