#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
Usage: Scripts/bootstrap-ghostty.sh [revision]

Build the arm64 Ghostty XCFramework and matching resources used by Space.
The revision defaults to the latest commit on Ghostty's main branch.

Examples:
  Scripts/bootstrap-ghostty.sh
  Scripts/bootstrap-ghostty.sh v1.2.0
  Scripts/bootstrap-ghostty.sh 4c725242b7dbe8c77c6e227ef1f9540c5ef17921
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: GhosttyKit.xcframework must be built on macOS" >&2
    exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "error: Space requires an arm64 macOS host for the native Ghostty build" >&2
    exit 1
fi

for command_name in git zig xcodebuild tic lipo; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command not found: $command_name" >&2
        exit 1
    fi
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
vendor_dir="$project_dir/Vendor/Ghostty"
source_dir="$project_dir/.build/ghostty-source"
repository_url="https://github.com/ghostty-org/ghostty.git"
requested_revision="${1:-main}"

if [ ! -f "$project_dir/Space.xcodeproj/project.pbxproj" ]; then
    echo "error: unable to locate the Space project root" >&2
    exit 1
fi

mkdir -p "$(dirname -- "$source_dir")"

if [ -d "$source_dir/.git" ]; then
    actual_origin=$(git -C "$source_dir" remote get-url origin)
    if [ "$actual_origin" != "$repository_url" ]; then
        echo "error: unexpected Ghostty cache origin: $actual_origin" >&2
        echo "expected: $repository_url" >&2
        exit 1
    fi
else
    if [ -e "$source_dir" ]; then
        echo "error: cache path exists but is not a Git checkout: $source_dir" >&2
        exit 1
    fi
    git clone --filter=blob:none --no-checkout "$repository_url" "$source_dir"
fi

echo "Fetching Ghostty..."
git -C "$source_dir" fetch --prune --tags origin

if [ "$requested_revision" = "main" ]; then
    resolved_revision="origin/main"
else
    resolved_revision="$requested_revision"
fi

commit=$(git -C "$source_dir" rev-parse "${resolved_revision}^{commit}")
git -C "$source_dir" checkout --detach "$commit"

echo "Building Ghostty commit $commit for arm64..."
(
    cd "$source_dir"
    zig build \
        -Doptimize=ReleaseFast \
        -Dsentry=false \
        -Demit-macos-app=false \
        -Demit-xcframework=true \
        -Dxcframework-target=native
)

built_xcframework="$source_dir/zig-out/macos/GhosttyKit.xcframework"
built_archive="$built_xcframework/macos-arm64/libghostty-internal.a"
built_ghostty_resources="$source_dir/zig-out/share/ghostty"
built_terminfo="$source_dir/zig-out/share/terminfo"

for required_path in \
    "$built_xcframework/Info.plist" \
    "$built_xcframework/macos-arm64/Headers/ghostty.h" \
    "$built_archive" \
    "$built_ghostty_resources" \
    "$built_terminfo"
do
    if [ ! -e "$required_path" ]; then
        echo "error: expected build output is missing: $required_path" >&2
        exit 1
    fi
done

archive_archs=$(lipo -archs "$built_archive")
if [ "$archive_archs" != "arm64" ]; then
    echo "error: expected an arm64-only archive, found: $archive_archs" >&2
    exit 1
fi

staging_dir=$(mktemp -d "$project_dir/.build/ghostty-install.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM

cp -R "$built_xcframework" "$staging_dir/GhosttyKit.xcframework"
mkdir -p "$staging_dir/Resources"
cp -R "$built_ghostty_resources" "$staging_dir/Resources/ghostty"
cp -R "$built_terminfo" "$staging_dir/Resources/terminfo"

binary_target="$vendor_dir/GhosttyKit.xcframework"
resources_target="$vendor_dir/Sources/GhosttyTerminal/Resources"

rm -rf "$binary_target" "$resources_target"
mv "$staging_dir/GhosttyKit.xcframework" "$binary_target"
mv "$staging_dir/Resources" "$resources_target"
printf '%s\n' "$commit" > "$vendor_dir/GHOSTTY_COMMIT"

echo "Installed Ghostty $commit:"
echo "  $binary_target"
echo "  $resources_target"
