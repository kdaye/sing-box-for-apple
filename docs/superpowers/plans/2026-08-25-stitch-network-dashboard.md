# Stitch Network Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the iPhone, iPad, and macOS card dashboard with the approved Stitch-style network control that starts in Rule mode, reports real traffic, switches actual outbound nodes, and copies diagnostics.

**Architecture:** Keep `ExtensionProfile` and the shared `CommandClient` authoritative. Add a small pure presentation model for traffic/group derivation, keep asynchronous commands in `OverviewViewModel`, and compose the screen from focused SwiftUI subviews used on both Apple UI platforms.

**Tech Stack:** Swift 5, SwiftUI, Combine, NetworkExtension, Libbox, XCTest, UIKit/AppKit clipboard APIs.

**Spec:** `docs/superpowers/specs/2026-08-25-stitch-network-dashboard-design.md`

## Global Constraints

- Preserve all pre-existing working-tree edits, especially the existing `OverviewView.swift` change that removed `ProfileCard`.
- Support iPhone, iPad, and macOS with one shared dashboard implementation; tvOS keeps its existing dashboard behavior.
- Every manual start must set Clash mode to the exact string `rule`; never expose `global` or `direct` controls.
- Disconnected means the extension is stopped and system networking is direct.
- Add no external fonts or packages.
- Report Bug only copies logs/diagnostics and shows `日志已复制，请发送给 Jay。`; it never transmits data.
- Treat command-client status and group events as authoritative.

---

### Task 1: Pure Dashboard Presentation Model

**Files:**
- Create: `ApplicationLibrary/Views/Dashboard/Overview/NetworkDashboardState.swift`
- Create: `ApplicationLibraryTests/NetworkDashboardStateTests.swift`
- Modify: `sing-box.xcodeproj/project.pbxproj` (add a filesystem-synchronized `ApplicationLibraryTests` unit-test target linked to `ApplicationLibrary`)

**Interfaces:**
- Consumes: `OutboundGroup` and integer traffic counters.
- Produces: `NetworkDashboardState.safeTrafficTotal(uplink:downlink:) -> Int64`, `NetworkDashboardState.primaryGroup(in:) -> OutboundGroup?`, `NetworkDashboardState.diagnostics(...) -> String`, and `NetworkDashboardPhase`.

- [ ] **Step 1: Add the failing unit-test target and tests**

Create a macOS/iOS-compatible unit-test target and tests covering saturation, group selection, and diagnostics:

```swift
import XCTest
@testable import ApplicationLibrary
import Library

final class NetworkDashboardStateTests: XCTestCase {
    func testTrafficTotalSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(NetworkDashboardState.safeTrafficTotal(uplink: .max, downlink: 1), .max)
    }

    func testPrimaryGroupIsFirstSelectableGroup() {
        let groups = [
            OutboundGroup(tag: "auto", type: "urltest", selected: "a", selectable: false, isExpand: false, items: []),
            OutboundGroup(tag: "proxy", type: "selector", selected: "hk", selectable: true, isExpand: false, items: []),
        ]
        XCTAssertEqual(NetworkDashboardState.primaryGroup(in: groups)?.tag, "proxy")
    }

    func testDiagnosticsContainsProfileNodeAndStatus() {
        let value = NetworkDashboardState.diagnostics(
            version: "1.0 (2)", status: "connected", profile: "work", group: "proxy", node: "hk"
        )
        XCTAssertTrue(value.contains("Profile: work"))
        XCTAssertTrue(value.contains("Node: hk"))
        XCTAssertTrue(value.contains("Status: connected"))
    }
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcodebuild test -project sing-box.xcodeproj -scheme ApplicationLibraryTests -destination 'platform=macOS' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `NetworkDashboardState` does not exist.

- [ ] **Step 3: Implement the minimal pure model**

Create:

```swift
import Foundation
import Library

enum NetworkDashboardPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

enum NetworkDashboardState {
    static func safeTrafficTotal(uplink: Int64, downlink: Int64) -> Int64 {
        let (sum, overflow) = uplink.addingReportingOverflow(downlink)
        return overflow ? .max : max(0, sum)
    }

    static func primaryGroup(in groups: [OutboundGroup]) -> OutboundGroup? {
        groups.first(where: { $0.selectable })
    }

    static func diagnostics(version: String, status: String, profile: String, group: String?, node: String?) -> String {
        ["Version: \(version)", "Status: \(status)", "Profile: \(profile)",
         "Group: \(group ?? "Unavailable")", "Node: \(node ?? "Unavailable")"].joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run the Task 1 command again. Expected: all `NetworkDashboardStateTests` pass.

- [ ] **Step 5: Commit the model and tests**

```bash
git add ApplicationLibrary/Views/Dashboard/Overview/NetworkDashboardState.swift ApplicationLibraryTests sing-box.xcodeproj/project.pbxproj
git commit -m "test: cover network dashboard state"
```

### Task 2: Rule-Only Lifecycle, Node Selection, and Clipboard Actions

**Files:**
- Modify: `ApplicationLibrary/Views/Dashboard/Overview/OverviewViewModel.swift`
- Modify: `ApplicationLibraryTests/NetworkDashboardStateTests.swift`

**Interfaces:**
- Consumes: `ExtensionProfile.start()`, `ExtensionProfile.stop()`, `LibboxNewStandaloneCommandClient().setClashMode(_:)`, `selectOutbound(_:outboundTag:)`, `CommandClient.logList`.
- Produces: `toggleConnection(profile:environments:) async`, `selectOutbound(groupTag:outboundTag:)`, `copyReport(...)`, `@Published phase`, and `@Published alert`.

- [ ] **Step 1: Add failing tests for action sequencing and report content**

Extract command effects behind injected closures in `OverviewViewModel.Dependencies` and test that start calls occur in this order: `start`, `rule`; a Rule error is followed by `stop`; selection forwards both tags; non-empty logs are joined with newlines while empty logs use `NetworkDashboardState.diagnostics`.

```swift
func testStartSetsRuleAfterServiceStarts() async {
    var events: [String] = []
    let dependencies = OverviewViewModel.Dependencies(
        start: { events.append("start") }, stop: { events.append("stop") },
        setRuleMode: { events.append("rule") },
        selectOutbound: { group, node in events.append("\(group):\(node)") },
        copy: { _ in }
    )
    let model = await OverviewViewModel(dependencies: dependencies)
    await model.startRuleConnection()
    XCTAssertEqual(events, ["start", "rule"])
}
```

- [ ] **Step 2: Run tests and verify the new test fails**

Run the Task 1 test command. Expected: `Dependencies` and `startRuleConnection()` are missing.

- [ ] **Step 3: Implement injectable effects and production wrappers**

Add a `Dependencies` value whose `.live(profile:)` closures call the existing profile and standalone command APIs. Keep `@Published phase` transient only, reconcile it from `ExtensionProfile.status`, reject duplicate toggles, and call `profile.stop()` if setting Rule mode throws. Implement selection with optimistic display owned by the sheet and authoritative reconciliation from group events.

Implement clipboard writing under conditional imports:

```swift
#if os(iOS)
UIPasteboard.general.string = report
#elseif os(macOS)
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(report, forType: .string)
#endif
alert = AlertState(title: String(localized: "Report Bug"), message: String(localized: "日志已复制，请发送给 Jay。"))
```

- [ ] **Step 4: Run unit tests**

Run the Task 1 command. Expected: sequencing, failure cleanup, selection forwarding, and report tests pass.

- [ ] **Step 5: Commit the action layer**

```bash
git add ApplicationLibrary/Views/Dashboard/Overview/OverviewViewModel.swift ApplicationLibraryTests/NetworkDashboardStateTests.swift
git commit -m "feat: add rule-only dashboard actions"
```

### Task 3: Stitch Dashboard and Node Picker

**Files:**
- Create: `ApplicationLibrary/Views/Dashboard/Overview/NetworkDashboardStyle.swift`
- Create: `ApplicationLibrary/Views/Dashboard/Overview/NetworkPowerControl.swift`
- Create: `ApplicationLibrary/Views/Dashboard/Overview/NetworkNodePicker.swift`
- Modify: `ApplicationLibrary/Views/Dashboard/Overview/OverviewView.swift`
- Modify: `SFIUITests/SnapshotTests.swift`

**Interfaces:**
- Consumes: Task 1 presentation helpers and Task 2 view-model actions.
- Produces: shared iOS/iPadOS/macOS Stitch dashboard; tvOS retains the current card grid.

- [ ] **Step 1: Add failing UI assertions for disconnected and connected controls**

Extend screenshot-mode UI tests to require accessibility identifiers:

```swift
func testDashboardExposesNetworkControls() {
    XCTAssertTrue(app.buttons["network.power"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["network.reportBug"].exists)
    XCTAssertTrue(app.staticTexts["network.currentNode"].exists)
}
```

- [ ] **Step 2: Run the UI test and verify it fails**

Run:

```bash
xcodebuild test -project sing-box.xcodeproj -scheme SFI -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO -only-testing:SFIUITests/SnapshotTests/testDashboardExposesNetworkControls
```

Expected: `network.power` is absent from the current dashboard.

- [ ] **Step 3: Implement visual tokens and the central control**

Define fixed Stitch colors (`#F8F9FF`, `#0D1C2D`, `#4ADE80`, `#006D36`) in `NetworkDashboardStyle`. Build the inset plate, outer ring, 192-point circular control, green connected glow, power/connecting labels, total traffic, and separate `↑`/`↓` rates in `NetworkPowerControl`. Use `GeometryReader` to cap plate width at 320 points and content width at 520 points; honor `accessibilityReduceMotion`.

- [ ] **Step 4: Implement the responsive page and node picker**

For iOS/macOS, replace the card grid with a centered `ScrollView` containing header, control, node row, Report Bug, and version. Bind values directly to `profile.status`, `commandClient.status`, `commandClient.groups`, and `commandClient.logList`. Present `NetworkNodePicker` as a sheet with one section per selectable group; each row shows tag, `displayType`, `delayString`, and a checkmark. Keep the existing `#if os(tvOS)` card grid path unchanged.

- [ ] **Step 5: Run the UI test and snapshot suite**

Run the Task 3 test command, then:

```bash
xcodebuild test -project sing-box.xcodeproj -scheme SFI -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO -only-testing:SFIUITests/SnapshotTests
```

Expected: controls exist and dashboard snapshot completes.

- [ ] **Step 6: Commit the dashboard UI**

```bash
git add ApplicationLibrary/Views/Dashboard/Overview SFIUITests/SnapshotTests.swift
git commit -m "feat: add Stitch network dashboard"
```

### Task 4: Localization and Cross-Platform Verification

**Files:**
- Modify: `Localizable.xcstrings`
- Modify: `ApplicationLibrary/Views/Dashboard/Overview/NetworkDashboardState.swift` only if localization requires moving a user-visible fallback string out of the pure model.

**Interfaces:**
- Consumes: complete dashboard implementation.
- Produces: localized user-visible copy and verified iOS/macOS builds.

- [ ] **Step 1: Add exact localized strings**

Add catalog entries for `网络工具`, `未连接`, `连接中`, `已连接`, `累计流量`, `实时上行`, `实时下行`, `当前服务器`, `当前配置自动选择`, `Report Bug`, and `日志已复制，请发送给 Jay。`. Preserve existing catalog edits and ordering conventions.

- [ ] **Step 2: Run focused unit tests**

```bash
xcodebuild test -project sing-box.xcodeproj -scheme ApplicationLibraryTests -destination 'platform=macOS' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass.

- [ ] **Step 3: Build the iOS application**

```bash
xcodebuild build -project sing-box.xcodeproj -scheme SFI -destination 'generic/platform=iOS' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Build the macOS applications**

```bash
xcodebuild build -project sing-box.xcodeproj -scheme SFM -destination 'platform=macOS' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO
xcodebuild build -project sing-box.xcodeproj -scheme SFM.System -destination 'platform=macOS' -derivedDataPath /tmp/sing-box-dashboard-derived CODE_SIGNING_ALLOWED=NO
```

Expected: both commands report `BUILD SUCCEEDED`.

- [ ] **Step 5: Inspect the final diff and commit verification fixes**

```bash
git diff --check
git status --short
git add Localizable.xcstrings ApplicationLibrary/Views/Dashboard/Overview ApplicationLibraryTests SFIUITests/SnapshotTests.swift sing-box.xcodeproj/project.pbxproj
git commit -m "chore: localize and verify network dashboard"
```

Only stage files belonging to this feature; leave unrelated pre-existing changes untouched.
