# macOS network filter

This directory contains the first true network-blocking vertical slice. It is
separate from process pause/unpause: the content filter denies selected public-
Internet flows while the process continues to run.

## Components

- `FilterExtension` is an `NEFilterDataProvider`. It identifies the process
  from the flow audit token, checks PID + executable path + process start time,
  drops matching new flows, and applies a drop verdict to matching flows that
  were already open. Its system-extension entry point starts Network Extension
  mode with `NEProvider.startSystemExtensionMode()`.
- `FilterHostCore` validates requests from the CLI, rejects PID reuse, stores
  temporary rules atomically in the shared App Group, and exposes a same-user
  Unix socket. The socket is mode `0600` and verifies the peer UID.
- `FilterHost` is a small menu-bar host app. It installs the system extension,
  enables `NEFilterManager`, and runs the local rule broker.
- `Sources/TrafficCtrlFilterProtocol` is the versioned JSON protocol shared by
  the CLI, host, and extension.

The design is fail-open. The host renews a three-second rule lease every second;
if the host or broker disappears, the extension discards its rules after that
lease. If the host, extension, shared rule store, or protocol is unavailable,
the CLI reports `[b]lock×` and never claims that traffic is blocked. Temporary
rules are also removed when their process exits or its PID is reused. Unblocking
permits new connections; a socket already dropped by macOS must reconnect.

## Developer prerequisites

1. Accept the installed Xcode licence: `sudo xcodebuild -license`.
2. Sign in to an Apple Developer Program team in Xcode.
3. Register the host and extension bundle identifiers used in `project.yml`.
4. Enable the Network Extension and App Groups capabilities for both IDs, and
   the System Extension capability for the host.
5. Create the App Group `group.com.stealthfactory.trafficctrl` and attach both
   targets to it.
6. Install XcodeGen, then run `xcodegen generate --spec macOS/project.yml`.
7. Set the Development Team for both generated targets, build the
   `TrafficCtrlFilterHost` scheme, and launch the app.
8. Approve the system extension and network filter when macOS requests it.

The unsigned SwiftPM build validates all three code layers without installing
or enabling a filter:

```sh
swift build -c release --target TrafficCtrlFilterEngine
swift build -c release --target TrafficCtrlFilterHost
swift build -c release
```

If `xcodebuild` reports that its licence has not been accepted, complete step 1
before generating or building the signed host. A valid Apple Development or
Developer ID signing identity is required for live TCP/UDP enforcement tests.

## Current enforcement semantics

- Rules apply to a single verified process lifetime, not merely a PID.
- The extension uses `sourceProcessAuditToken`, falling back to the source-app
  audit token on older flow metadata.
- Public IPv4 and globally routed IPv6/NAT64 endpoints are blocked. Hostnames
  are treated as public except for `localhost` and `.local`; when macOS has not
  populated the remote hostname yet, the selected blocked process is denied to
  prevent an initial leak.
- Rule changes are observed within roughly 200 ms. Existing allowed flows are
  changed to a drop verdict; unblocking relies on application reconnection.
- Rules are intentionally temporary. Persistent executable or signing-identity
  policies remain a later roadmap milestone.

Before release, validate TCP, UDP, IPv4, IPv6, process restart/PID reuse,
existing-flow termination, sleep/wake, crashes, VPN coexistence, other content
filters, installation, upgrade, and removal on real signed builds.
