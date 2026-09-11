# Space Ghostty integration

This package contains the Swift/AppKit adapter that lets Space use the
locally built Ghostty C library.

`GhosttyKit.xcframework` and `Sources/GhosttyTerminal/Resources` are generated
from the same Ghostty commit and intentionally ignored by Git. Bootstrap or
upgrade both artifacts together from the repository root:

```sh
Scripts/bootstrap-ghostty.sh
```

The default is the latest commit on Ghostty's `main` branch. Pass a tag or
commit to reproduce a specific version:

```sh
Scripts/bootstrap-ghostty.sh "$(cat Vendor/Ghostty/GHOSTTY_COMMIT)"
```

To build from an existing clean Ghostty checkout without fetching, switching
revisions, or cleaning that checkout, pass its path. An optional revision
asserts that its current `HEAD` is the expected commit:

```sh
Scripts/bootstrap-ghostty.sh --source /path/to/ghostty
Scripts/bootstrap-ghostty.sh --source /path/to/ghostty "$(cat Vendor/Ghostty/GHOSTTY_COMMIT)"
```

The script requires an arm64 Mac, Xcode command-line tools, Zig, Git, and
`tic`. Unless `--source` is used, it keeps a shallow Ghostty checkout in
`.build/ghostty-source`. It installs an arm64-only XCFramework, replaces the
matching runtime resources, and writes the resolved commit to `GHOSTTY_COMMIT`.
