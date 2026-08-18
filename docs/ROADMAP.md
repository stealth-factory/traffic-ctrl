# Traffic Ctrl roadmap

This roadmap records the intended evolution of Traffic Ctrl from the current
macOS Swift prototype into a cross-platform network monitor and controller.
It is a direction of travel rather than a promise of release dates.

## Architectural decision

Traffic Ctrl will use a shared Rust core and terminal interface with separate
privileged networking backends for macOS and Linux:

```text
                       traffic-ctrl / trctrl
                         Rust core and TUI
                                │
                    versioned local IPC protocol
                       ┌────────┴────────┐
                       │                 │
              macOS Swift service   Linux service
              Network Extension     Rust + eBPF
```

Swift will remain the macOS integration language. The macOS service will own
traffic collection, process and flow attribution, byte accounting, and network
allow/block decisions through Apple's Network Extension APIs. The portable
process model, statistics, charts, rules, configuration, and user interaction
will move to Rust. Linux will implement the same backend contract with Rust and
eBPF.

The existing process pause/unpause control remains a diagnostic feature. It is
distinct from network block/unblock: pausing suspends all process activity,
whereas blocking denies network traffic while allowing CPU, disk, timers, and
IPC to continue.

## Phase 1: define the backend contract

Before backend work begins, establish the release foundation described in the
[release guide](RELEASING.md): cross-architecture CI, Semantic Versioning,
generated changelogs, checksummed GitHub Release assets, and reproducible
version metadata.

- Specify a versioned, platform-neutral local IPC protocol.
- Cover process and flow discovery, streaming RX/TX updates, endpoint data,
  reset, block, unblock, blocked state, and structured errors.
- Separate temporary PID rules from persistent application or executable
  identity rules.
- Define privilege boundaries, authentication, reconnect behaviour, and a
  fail-open policy if the networking service becomes unavailable.
- Keep the protocol independent of the current Swift TUI so both Swift and
  Rust clients can use it during migration.

## Phase 2: prove macOS network enforcement in Swift

Build a focused vertical slice before porting the product core:

- Package a signed macOS host app and Network Extension/system extension.
- Attribute flows to their originating processes using supported macOS process
  identity data.
- Collect per-flow and per-process RX/TX totals and current rates.
- Implement network block/unblock for the selected process without suspending
  it.
- Apply rules to new flows and determine reliable behaviour for flows that are
  already open.
- Preserve the current public-Internet-only scope and endpoint reporting.
- Connect the existing Swift TUI to the service through the new IPC contract.

This phase is complete only after validating:

- TCP and UDP traffic;
- block, unblock, and application reconnection behaviour;
- process exits, restarts, helpers, and PID reuse;
- extension/client crashes and safe recovery;
- VPNs and coexistence with other network filters;
- signing, installation, user approval, upgrades, and removal; and
- traffic accounting against independent macOS measurements.

The goal is a reliable enforcement backend, not additional polish in the Swift
interface.

## Phase 3: move the portable core and TUI to Rust

- Rebuild the terminal UI, charts, sorting, navigation, history, and rules in
  Rust.
- Preserve the `traffic-ctrl` command and `trctrl` alias.
- Maintain the current keyboard controls and responsive layout.
- Replace direct Swift collector access with the established IPC client.
- Run the Swift and Rust clients against the same fixtures during the
  transition to prevent behavioural drift.
- Retire the Swift TUI only after the Rust client reaches feature parity.

The Swift Network Extension and its service remain the permanent macOS backend.

## Phase 4: add the Linux backend

- Implement per-process/cgroup traffic accounting with eBPF ingress and egress
  hooks.
- Implement block/unblock by changing pass/drop policy without freezing the
  process.
- Support current flows, newly created flows, TCP, UDP, IPv4, and IPv6.
- Use the same IPC protocol and behavioural semantics as the macOS service.
- Package the privileged service for common systemd-based distributions and
  document its required capabilities.
- Add kernel-capability detection and expose unsupported states instead of
  presenting controls that will fail.

## Phase 5: cross-platform parity and hardening

- Add shared integration tests and recorded traffic fixtures.
- Define consistent accounting semantics, including headers and retransmits.
- Add rule persistence, import/export, and auditable block history.
- Provide clear process identity and helper-process handling.
- Test suspend, sleep, network changes, VPN changes, service upgrades, and
  abnormal termination.
- Produce signed macOS releases and reproducible Linux packages.
- Document platform differences where identical behaviour is impossible.

## Known limits

- Domain attribution is best-effort. Encrypted DNS, proxies, VPNs, CDNs,
  shared addresses, and connection reuse can obscure the originating domain.
- An endpoint or open file is a debugging clue; encrypted application traffic
  generally prevents proof that a particular file is being transferred.
- Unblocking does not guarantee that an interrupted connection survives. Some
  applications will need to reconnect.
- PID-only policies are temporary by design because PIDs are reused. Persistent
  rules need a stable, platform-appropriate application identity.
- The macOS backend requires signing and user approval. The Linux backend
  requires elevated installation privileges or narrowly scoped capabilities.

## Delivery principle

Keep Traffic Ctrl usable throughout the migration. Each backend and client must
be replaceable behind the IPC boundary; the project should not require a
single, all-at-once rewrite.
