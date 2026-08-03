# Space Development Guidelines

import skill in /code/agent/skills/host-command-runner

## Restarting the Application

To restart Space, run these commands in order on the macOS host. Do not run `open` alone, because it may only activate the existing process.

```sh
xcodebuild -project Space.xcodeproj -scheme Space -configuration Debug -derivedDataPath DerivedData -destination platform=macOS CODE_SIGNING_ALLOWED=NO test -only-testing:SpaceUITests/SpaceUITests/testTerminateRunningApplication
```

Only after the UI test displays `TEST SUCCEEDED`, run:

```sh
open DerivedData/Build/Products/Debug/Space.app
```

`testTerminateRunningApplication()` in `SpaceUITests/SpaceUITests.swift` terminates the application and verifies that its state is `.notRunning`.
