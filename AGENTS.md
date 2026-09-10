# Traffic Ctrl contributor guide

## Product and commands

- Product name: **Traffic Ctrl**.
- Canonical executable: `traffic-ctrl`.
- Short executable alias: `trctrl`.
- Canonical planning and issue tracker: [Traffic Ctrl on Linear](https://linear.app/stealth-company/project/traffic-ctrl-d494278d9328/overview).
- Keep this naming consistent in user-facing text, package metadata,
  executable names, source paths, and documentation.

## Scope and architecture

- The Rust client targets macOS and Linux; the Swift integration targets macOS
  13 or later.
- `/usr/bin/nettop` is the macOS traffic source. Its initial lifetime-counter sample
  must be discarded; later delta samples are accumulated from tool launch.
- Public-Internet mode counts only globally routable remote endpoints.
- Network sampling, reverse DNS, process inspection, and terminal output must
  remain off the keyboard/input loop.
- Reverse DNS is best effort. Never present a resolved hostname as proof of the
  exact application-level domain requested.
- Open files are correlation clues, not proof that a file is being transferred.

## Interaction contract

- Controls act on one keypress without requiring Return.
- `↑`/`↓` or `j`/`k` moves the current selection.
- `Return` or `→` opens process details.
- `Esc` or `←` returns to the main process list.
- `s` switches between total-data and live-bandwidth sorting.
- In details, `Tab` cycles through endpoints, network connections, and open
  files; `e` and `f` remain direct endpoint and file shortcuts.
- The endpoint focus shows a compact RX-above-zero/TX-below-zero chart directly
  beneath the selected endpoint. Endpoint histories reset with all other stats.
- `p` requires confirmation before pausing the selected process in either
  view; `u` resumes it. Pause notices must identify the process by name and PID
  and make clear that only that process is affected.
- `b` controls public-Internet block/unblock for the selected process. Blocking
  requires confirmation; unblocking is immediate. Never display a blocked
  state unless the signed filter service confirms it, and render the control as
  unavailable when that service is missing or disabled.
- The footer must remain visible and describe the controls available in the
  current view.

## Worktrees

- Create all auxiliary Git worktrees inside
  `<project-root>/.claude/worktrees/<branch-name>`.
- Do not create worktrees as siblings of the project directory.

## Building and verification

The cross-platform Rust client lives under `rust/`. Keep the Swift client
available while migration validation continues. Build and test the portable
core and client with:

```sh
cargo fmt --all -- --check
cargo test --workspace
cargo build --release --workspace
```

The Rust executables are `target/release/traffic-ctrl` and
`target/release/trctrl`. On Linux the
interim `ss` collector is TCP-only; do not describe it as full eBPF accounting
or enforcement.

Build both executables with:

```sh
swift build -c release
```

Verify both entry points:

```sh
.build/release/traffic-ctrl --help
.build/release/trctrl --help
.build/release/traffic-ctrl --version
.build/release/trctrl --version
```

After changing interaction or rendering code, also run the release binary in a
real PTY and exercise rapid keys, detail entry/exit, endpoint/file focus, reset,
and quit. Do not report the dormant XCTest files as passing unless a test target
has been restored and actually run successfully with the active toolchain.

After every implemented application update, rebuild the release binary and
restart the preview in the right-hand Herdr pane. Verify that the pane's
foreground process is the new `traffic-ctrl` binary and inspect the visible
screen for the updated behaviour before reporting completion.

## Versions and releases

- Use Conventional Commit subjects for changes intended to drive releases.
- Release Please owns `.release-please-manifest.json`, `CHANGELOG.md`, release
  tags, and updates to `Sources/TrafficCtrl/Version.swift`.
- Do not edit generated version or changelog entries manually except when
  repairing release automation.
- CI must build both ARM64 and Intel macOS executables. A release is complete
  only after both archives and `SHA256SUMS` are attached to the GitHub Release.
- Follow `docs/RELEASING.md` for repository setup, release operation, and
  recovery.
