# Space 开发约定

## 重启应用

重启 Space 时，必须先通过现有 UI 测试终止正在运行的应用，再打开最新的 Debug 构建。不要只执行 `open`，因为 macOS 可能只会激活已有进程，而不是真正重启。

在 macOS 主机上依次执行：

```sh
xcodebuild -project Space.xcodeproj -scheme Space -configuration Debug -derivedDataPath DerivedData -destination platform=macOS CODE_SIGNING_ALLOWED=NO test -only-testing:SpaceUITests/SpaceUITests/testTerminateRunningApplication
```

确认 UI 测试成功并显示 `TEST SUCCEEDED` 后，再执行：

```sh
open DerivedData/Build/Products/Debug/Space.app
```

在开发容器中，使用主机命令桥分别执行上述两条命令；必须等待 UI 测试完成且成功后，才能打开应用。退出流程由 `SpaceUITests/SpaceUITests.swift` 中的 `testTerminateRunningApplication()` 负责，它调用 `XCUIApplication.terminate()` 并验证应用状态为 `.notRunning`。
