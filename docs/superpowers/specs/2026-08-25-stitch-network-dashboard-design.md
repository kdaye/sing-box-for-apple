# Stitch Network Dashboard Design

## Goal

Replace the existing card-based dashboard on iPhone, iPad, and macOS with one shared SwiftUI interface matching the Stitch project **3D Proxy Traffic Controller**. The central control starts and stops the existing sing-box service, shows live and cumulative traffic, identifies the selected outbound node, and lets the user choose another node.

The dashboard exposes only two user-facing routing states:

- Disconnected: the extension is stopped and traffic uses the system network directly.
- Connected: the extension is running in Clash `rule` mode.

Every new connection must explicitly set the Clash mode to `rule`. The dashboard must not offer `global` or `direct` mode controls.

## Scope

### Included

- A shared responsive dashboard for iOS, iPadOS, and macOS.
- Stitch-inspired layout, colors, depth, and state transitions.
- Service start and stop through the existing `ExtensionProfile` APIs.
- Live uplink and downlink rates.
- Combined cumulative traffic.
- Display and selection of actual outbound nodes.
- Copying diagnostic logs through the Report Bug action.
- Unit tests for derived dashboard state and focused build verification for iOS and macOS.

### Excluded

- A `global` or `direct` mode selector.
- Automatic submission of logs or opening a feedback website.
- A new background service or a second command channel.
- Redesigning profile, log, connection, group, or settings screens.
- Matching the new dashboard on tvOS.

## Existing Capabilities

The implementation will reuse existing project components:

- `ExtensionProfile` and the current start/stop flow for service lifecycle.
- `ExtensionEnvironments.commandClient` for status, traffic, groups, and Clash mode events.
- `LibboxStatusMessage` for `uplink`, `downlink`, `uplinkTotal`, and `downlinkTotal`.
- `LibboxOutboundGroup` data and `selectOutbound` for node selection.
- Existing alert infrastructure for connection, mode, and node-selection failures.

No duplicate connection state or traffic transport will be introduced.

## Page Architecture

The current `OverviewView` card grid will become a single vertical dashboard with five regions:

1. Header: shield icon and “网络工具”.
2. Central control: inset square plate, circular ring, and large power button.
3. Traffic readout: cumulative traffic plus current uplink and downlink.
4. Outbound selector: selected node and its containing proxy group.
5. Footer: Report Bug and app version.

Existing app navigation remains available. Only the dashboard's main content is replaced.

The implementation should split visual components and derived state into focused units instead of adding all behavior to `OverviewView`. `OverviewViewModel` will own user actions and deterministic presentation logic; small SwiftUI components will render the power control, traffic readout, and node selector.

## Responsive Layout

The phone layout follows the Stitch 390-by-884 composition. The center plate targets approximately 320 points and the inner power button approximately 192 points, shrinking when horizontal or vertical space is constrained.

iPad and macOS use the same information hierarchy and visual treatment. Content is centered with a maximum width near 520 points rather than stretching across the window. A scroll container prevents clipping in short windows and with accessibility text sizes.

The visual theme remains consistent across platforms:

- Cool off-white background.
- Dark blue-gray primary text.
- Bright green active surface and glow.
- Layered light/dark shadows for the inset well and raised controls.
- Compact technical labels and monospaced numeric data where appropriate.

System fonts will approximate the Stitch Space Grotesk/Geist pairing so the change does not add font dependencies. The dashboard intentionally retains this light Stitch theme in both system appearances for cross-platform fidelity.

## Connection State Machine

The control derives its stable state from `ExtensionProfile.status`, with a local transient state guarding asynchronous user actions.

### Start

1. The user presses the disconnected power button.
2. The button enters a connecting state and rejects duplicate presses.
3. The existing service-start operation runs.
4. Once the command channel is available, Clash mode is explicitly set to `rule`.
5. The connected dashboard appears and starts rendering traffic and group events.

If service start or mode selection fails, the transient state ends, the UI follows the actual extension status, and the existing alert mechanism reports the error. If the extension started but setting `rule` fails, the implementation must not claim a successful Rule connection: it surfaces the mode error and calls `ExtensionProfile.stop()` to return to the disconnected state.

### Stop

1. The user presses the connected power button.
2. The existing service-stop operation runs.
3. Traffic and node readouts hide when the extension reaches a disconnected state.
4. The central control returns to `DISCONNECTED`.

Stopping the service represents direct system networking. No Clash `direct` mode command is sent or shown.

### External State Changes

On-demand connection changes, system extension changes, or changes made outside the dashboard are reflected from `ExtensionProfile.status`. The dashboard must not keep an independent long-lived boolean that can drift from the real service state.

## Traffic Semantics

When `trafficAvailable` is true, the connected control displays:

- Total traffic: `uplinkTotal + downlinkTotal`, formatted with `LibboxFormatBytes`.
- Current upload: `uplink`, formatted as bytes per second.
- Current download: `downlink`, formatted as bytes per second.

Arithmetic must avoid signed overflow by using a saturating or otherwise safe sum before formatting. Until status data becomes available, connected fields display placeholders rather than fabricated values. Disconnected state hides traffic values, matching the Stitch interaction.

## Outbound Resolution and Selection

The dashboard consumes the groups already published by `CommandClient`.

- The primary group is the first group where `selectable == true`.
- The main page displays that group's `selected` outbound tag as the current server and the group tag as secondary context.
- Pressing the node area opens a platform-appropriate sheet or popover.
- The selector lists all selectable groups in sections and all of their outbound items.
- Each item shows its tag, protocol/display type, and URL-test delay when available.
- Selecting an item calls the existing standalone command client's `selectOutbound(groupTag:outboundTag:)` flow.

Selection is optimistic for responsiveness. Incoming group events remain authoritative and reconcile the display. Errors use the existing alert UI.

If there is no selectable group, the page displays “当前配置自动选择” and disables node selection. The Stitch mock's IP address is replaced by the real proxy-group name because the current command API does not expose a reliable server IP.

## Report Bug

`REPORT BUG` never sends data or opens a URL.

When pressed, it copies the current in-memory command-client log to the system clipboard. iOS/iPadOS use `UIPasteboard`; macOS uses `NSPasteboard`.

If the log is empty, the copied text contains available basic diagnostics instead:

- App version/build.
- Extension connection status.
- Selected profile name or ID.
- Current selected proxy group and outbound node.

After a successful clipboard write, show the localized message:

> 日志已复制，请发送给 Jay。

Clipboard errors, where observable, use the existing alert infrastructure. No sensitive configuration contents, credentials, or automatic external transmission are included.

## Error Handling and Accessibility

- Disable the central button during start and stop transitions.
- Preserve the last authoritative node value while group updates are pending.
- Use existing alerts for service, mode, and node-selection errors.
- Provide accessibility labels and values for the power button, traffic fields, current node, and Report Bug.
- Do not rely only on green color to communicate connection state; labels and the power symbol also change.
- Respect Reduce Motion by replacing glow/scale transitions with simple opacity changes where practical.

## Testing and Verification

Unit tests will cover deterministic presentation behavior:

- Safe cumulative traffic calculation and formatting inputs.
- Primary selectable-group resolution.
- Selected-node resolution and the no-selectable-group fallback.
- Connected, connecting, and disconnected presentation state.
- Start sequencing that requires Rule mode before reporting success.
- Diagnostic fallback text when logs are empty.

Integration-oriented verification will cover:

- Existing start and stop APIs are invoked once per press.
- Node selection receives the correct group and outbound tags.
- Report Bug writes expected content to a clipboard abstraction.

Final verification will build the relevant iOS and macOS schemes. Screenshot mode will exercise disconnected and connected layouts at phone and wider desktop sizes, including a short-height window to confirm scrolling.

## Acceptance Criteria

- iPhone, iPad, and macOS dashboards share one Stitch-style interface.
- The central button starts and stops the real project service.
- Every user-initiated start configures `rule` mode; no other modes are offered.
- Connected state shows real combined totals and separate live upload/download rates.
- The displayed server is the actual selected outbound node.
- Users can switch nodes across selectable proxy groups.
- Disconnected state represents direct system networking.
- Report Bug copies logs or fallback diagnostics and displays “日志已复制，请发送给 Jay。”.
- Existing non-dashboard navigation remains usable.
- Focused tests pass and both iOS and macOS targets build.
