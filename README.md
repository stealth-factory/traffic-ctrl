# Traffic Ctrl

**Traffic Ctrl** (`traffic-ctrl`, or the shorter `trctrl` alias) is a small macOS
command-line monitor that ranks processes by the
public-Internet traffic they have used since the tool was launched. It also shows each
process's current download, upload, and combined transfer rates.

The main view includes a scrolling RX/TX line chart aggregated across all
monitored processes. Opening a process switches the chart to that process's
own receive and transmit history. Cyan RX rises above the zero axis and magenta
TX descends below it. Each half has a labelled independent scale so both remain
visible when one direction is much busier; up to 240 samples are retained.

The chart and process table use the terminal's full width. Process name and PID
have separate columns, the process name expands into available space, and less
important traffic columns collapse automatically in narrow terminals.

It uses macOS's built-in `nettop`; no kernel extension, packet capture, or
always-on background service is required.

## Build and run

Requires macOS 13 or later and the Xcode Command Line Tools.

```sh
swift build -c release
.build/release/traffic-ctrl

# Short alias
.build/release/trctrl
```

For a command available from anywhere:

```sh
install -m 755 .build/release/traffic-ctrl /usr/local/bin/traffic-ctrl
install -m 755 .build/release/trctrl /usr/local/bin/trctrl
```

You may need `sudo` for the install command, depending on the ownership of
`/usr/local/bin`.

## Usage

```text
traffic-ctrl [options]

  -i, --interval SECONDS  Sampling interval (default: 1, minimum: 0.2)
  -n, --limit COUNT       Maximum processes to show (default: auto-fit terminal)
      --external          Public Internet only (default; compatibility alias)
      --all-external      Include LAN, multicast and other non-loopback traffic
      --sort MODE         Initial sort: total or live (default: total)
      --plain             Do not clear the terminal between updates
  -h, --help              Show this help
```

Examples:

```sh
# Show the 20 busiest processes, refreshed every second
traffic-ctrl

# Show the top 10 public-Internet users
trctrl --limit 10 --external
```

While it is running, enter one of these controls:

- `↑`/`↓` or `j`/`k` selects and scrolls through processes.
- `Return` or `→` opens the selected process's traffic, connection, and
  open-file details.
- The detail view ranks every observed remote endpoint by its since-launch
  traffic and shows its live download and upload rates. Press `e` to select and
  scroll endpoints; the highlighted endpoint expands to show its own compact
  RX/TX history chart. Press `f` to select and scroll open files, or press `Tab`
  to cycle through endpoints, current network connections, and open files.
- `c` copies the active section's selected domain or IP address, network
  connection, or full file path to the macOS clipboard.
- `p` in either view asks for confirmation, then pauses the selected process for
  up to 30 seconds; press `u` to unpause it early.
- `Esc` or `←` returns to the ranked process list.
- `[s]ort` switches between total data and live bandwidth (`t` remains a
  compatibility shortcut).
- `[r]eset stats` resets every process's accumulated statistics to zero.
- `[q]uit` exits.

Each control responds to a single keypress; no Return key is required.

Process pausing is a short diagnostic aid, not a network firewall. It uses
`SIGSTOP`, so CPU, disk access, timers, IPC and network activity all stop. Traffic Ctrl
automatically sends `SIGCONT` after 30 seconds, on reset, and on a normal or
signal-driven exit. A force-quit or machine failure cannot run that cleanup, so
use the control carefully. macOS may also deny control of processes owned by
another user.

The detail screen correlates current sockets with relevant files currently open
by the process. Because most Internet traffic is encrypted, an open file is a
debugging clue rather than proof that the file is being uploaded or downloaded.
Remote IP addresses are resolved to hostnames in the background when reverse
DNS is available. A hostname is a best-effort label, not necessarily the exact
domain originally requested: CDNs, shared addresses, encrypted DNS and reused
connections can hide or combine application-level domains.

## Notes

- Totals begin at zero when Traffic Ctrl starts. Existing traffic from before
  launch is deliberately excluded.
- The default strict filter counts a connection only when its remote endpoint
  is a globally routable IPv4 or IPv6 address. LAN, loopback, link-local,
  multicast, wildcard and reserved endpoints are excluded.
- Processes are identified by the process name and PID reported by `nettop`.
- Processes remain in the accumulated ranking when `nettop` temporarily stops
  reporting them or their network connections close.
- The results are an operational view of socket traffic, not billing-grade
  metering. macOS may attribute traffic from proxies, VPNs, or system services
  to those intermediary processes.
