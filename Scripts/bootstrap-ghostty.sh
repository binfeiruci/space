#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
Usage: Scripts/bootstrap-ghostty.sh [--source PATH] [revision]

Build the arm64 Ghostty XCFramework and matching resources used by Space.
Without --source, the revision defaults to Ghostty's main branch and is
fetched into a script-managed shallow checkout. With --source, the existing
checkout's current HEAD is used without fetching, checking out, or cleaning it.

Examples:
  Scripts/bootstrap-ghostty.sh
  Scripts/bootstrap-ghostty.sh v1.2.0
  Scripts/bootstrap-ghostty.sh 4c725242b7dbe8c77c6e227ef1f9540c5ef17921
  Scripts/bootstrap-ghostty.sh --source /path/to/ghostty
  Scripts/bootstrap-ghostty.sh --source /path/to/ghostty 4c725242b7dbe8c77c6e227ef1f9540c5ef17921
EOF
}

source_override=""
requested_revision=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --source)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "error: --source requires a path" >&2
                exit 2
            fi
            source_override=$2
            shift 2
            ;;
        --source=*)
            source_override=${1#--source=}
            if [ -z "$source_override" ]; then
                echo "error: --source requires a path" >&2
                exit 2
            fi
            shift
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$requested_revision" ]; then
                echo "error: only one revision may be specified" >&2
                usage >&2
                exit 2
            fi
            requested_revision=$1
            shift
            ;;
    esac
done

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
build_dir="$project_dir/.build"
repository_url="https://github.com/ghostty-org/ghostty.git"

if [ ! -f "$project_dir/Space.xcodeproj/project.pbxproj" ]; then
    echo "error: unable to locate the Space project root" >&2
    exit 1
fi

mkdir -p "$build_dir"

if [ -n "$source_override" ]; then
    if ! source_dir=$(CDPATH= cd -- "$source_override" 2>/dev/null && pwd); then
        echo "error: Ghostty source directory does not exist: $source_override" >&2
        exit 1
    fi
    if ! git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "error: --source is not inside a Git checkout: $source_dir" >&2
        exit 1
    fi
    source_dir=$(git -C "$source_dir" rev-parse --show-toplevel)
    if [ -n "$(git -C "$source_dir" status --porcelain)" ]; then
        echo "error: existing Ghostty checkout has uncommitted changes: $source_dir" >&2
        exit 1
    fi
    commit=$(git -C "$source_dir" rev-parse --verify "HEAD^{commit}")
    if [ -n "$requested_revision" ]; then
        expected_commit=$(git -C "$source_dir" rev-parse --verify "${requested_revision}^{commit}")
        if [ "$commit" != "$expected_commit" ]; then
            echo "error: existing checkout HEAD does not match $requested_revision" >&2
            echo "HEAD:     $commit" >&2
            echo "expected: $expected_commit" >&2
            exit 1
        fi
    fi
    echo "Using existing Ghostty checkout at $source_dir (commit $commit)."
else
    source_dir="$build_dir/ghostty-source"
    requested_revision=${requested_revision:-main}

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
        git init --quiet "$source_dir"
        git -C "$source_dir" remote add origin "$repository_url"
    fi

    if [ "$requested_revision" = "main" ]; then
        fetch_revision="refs/heads/main"
    else
        fetch_revision="$requested_revision"
    fi

    echo "Fetching Ghostty revision $requested_revision (depth 1)..."
    git -C "$source_dir" fetch --depth=1 --no-tags origin "$fetch_revision"
    commit=$(git -C "$source_dir" rev-parse --verify "FETCH_HEAD^{commit}")
    git -C "$source_dir" checkout --detach --force "$commit"

    # Remove ignored outputs from the previous revision so the installed bundle
    # can only contain files produced by this build. The checkout is script-owned.
    git -C "$source_dir" clean -ffdX
fi

if [ ! -f "$source_dir/build.zig" ]; then
    echo "error: Ghostty build.zig is missing from source directory: $source_dir" >&2
    exit 1
fi

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

built_xcframework="$source_dir/macos/GhosttyKit.xcframework"
if [ ! -d "$built_xcframework" ]; then
    # Ghostty revisions before the XCFramework output move used this path.
    built_xcframework="$source_dir/zig-out/macos/GhosttyKit.xcframework"
fi
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

staging_dir=$(mktemp -d "$build_dir/ghostty-install.XXXXXX")
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
