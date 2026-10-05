# ztb-health

> **In development — unofficial, and not supported by Zscaler.**
> This is a personal project. It is not a Zscaler product, is not endorsed,
> maintained or supported by Zscaler in any way, and comes with no warranty
> of any kind. Zscaler Support will not accept cases arising from its use.
> Validate anything it reports against the appliance before acting on it.

A read-only health check for Zscaler **Zero Trust Branch** appliances.

It connects to the appliance's operator CLI (`zcli`) over SSH, runs a set of
query commands in a single session, and prints a PASS / WARN / FAIL report.

```
  [PASS] WAN interface              ge2 UP — 192.0.2.10/24
  [WARN] Boot image                 default (8.1.2+b257) != active (8.1.2-P1+b323)
                                    reboots stay on 8.1.2-P1+b323; a factory reset reverts
                                    to 8.1.2+b257
                                    fix with: software mkdefault 8.1.2-P1+b323
```

## Quick start

```bash
./ztb-health.sh
```

With no arguments it asks for what it needs:

```
Appliance management address: 192.0.2.10
Username [admin]:
admin@192.0.2.10's password:
```

Press Enter to accept `admin`. The password prompt comes from `ssh` itself,
so nothing is written to disk. Any answer can be given up front instead:

```bash
./ztb-health.sh -H 192.0.2.10 -u admin
```

```bash
ZTB_HOST=192.0.2.10 ./ztb-health.sh            # host from the environment
./ztb-health.sh -H 192.0.2.10 --no-color > branch-health.txt
./ztb-health.sh -H 192.0.2.10 --keep-transcript   # keep the raw CLI capture
```

```bash
./ztb-health.sh -H 192.0.2.10 --evidence > gw1.txt   # + raw data appendix
```

```bash
./ztb-health.sh -H 192.0.2.10 --no-tunnel-stats   # skip the tunnel counters
./ztb-health.sh -H 192.0.2.10 --max-routes 0      # list every route, uncapped
```

Run `./ztb-health.sh --help` for all options.

## Is it safe to run in production?

Yes. It is read-only by construction:

- Every command issued is a `show`/query. Nothing configures, restarts or
  reboots anything.
- A **deny-list runs before the script connects** and aborts if a mutating
  command (`run …`, `config …`, `software install|activate|…`, `clear
  web-proxy`, `dhcpcli … set-debug-level`) ever appears in the command list.
  This guards against a future edit turning a query into an outage.
- The heaviest command is `top -b -n 1`. No packet captures, no `tcpdump`,
  no traffic generated beyond the appliance's own built-in reachability
  probes.

A run takes roughly 30–60 seconds and opens one SSH connection.

## Requirements

`bash` 3.2+, OpenSSH, `awk`, `sed`, `grep`. **GNU coreutils are not
required** — all date arithmetic is done in `awk`, and `timeout`/`setsid`
are used only if present.

| Platform | Interactive | Unattended |
|---|---|---|
| Linux / WSL | yes | yes |
| macOS | yes | needs `sshpass` |
| Windows (Git Bash) | yes | not supported |

Tested against ZTB OS **8.1.2 (b226)** and **8.1.2-P1 (b323)**.

## Authentication

**Interactive (recommended).** With a terminal, `ssh` prompts for the
password itself. The password never reaches the filesystem, the process
table, or your shell history — `ssh` reads it from `/dev/tty` while the
command list arrives on stdin.

**Unattended.** In preference order:

1. **`ZTB_PASSWORD`** environment variable.
2. **`-c <file>`** with `user <name>` / `password <secret>` lines.

**SSH keys are not an option.** The appliance is a locked-down device: `zcli`
is a restricted command set rather than a shell, and nothing in it installs
an authorized key. Unattended runs therefore always involve a password, which
is why they need `sshpass` on macOS and are unsupported on Windows Git Bash —
neither `sshpass` nor `setsid` is available there, so the password cannot be
handed to `ssh` without a terminal.

A credentials file is **never** read implicitly — you must name it with
`-c`. Keep it outside the repository; `.gitignore` covers the common names
but that is a safety net, not a control.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | all checks passed |
| 1 | warnings only |
| 2 | one or more failures |
| 3 | could not connect or parse |
| 64 | bad usage, or a mutating command was blocked |

Suitable for cron or CI:

```bash
./ztb-health.sh -H 192.0.2.10 --no-color || echo "branch unhealthy"
```

## What it checks

Eleven sections, ~50 checks: identity and boot-image consistency; WAN,
Internet, portal and analytics reachability; system services; container
state; ZPA config, published scope and certificate expiry; interfaces,
next-hop resolution and overlay interface state; the routing inventory
(connected VLANs, static routes, BGP- and OSPF-learned routes); tunnel
liveness (counter deltas, BGP adjacency, broker sessions, IPsec SAs); DNS
proxy and redirect; firewall default policy; ZTP state; CPU, memory and
load; recent journal errors.

### Routing inventory (`ROUTING & SEGMENTS`)

Answers three questions that come up on every branch call: what segments does
this appliance terminate, what was routed by hand, and what is it learning
dynamically.

```
  [WARN] Connected segments         6 segments (4 tagged VLANs) — down: ge2.30(DOWN)
                                    a down segment carries no traffic — confirm against the site design
                                    vlan   iface          subnet              address          state
                                    -      ge5            10.10.0.0/24        10.10.0.10       UP
                                    20     ge2.20         10.10.20.0/24       10.10.20.1       UP
                                    30     ge2.30         (no IPv4 subnet)    -                DOWN
  [INFO] Static routes              1 site-specific + 2 default route(s) in the kernel FIB
  [PASS] BGP-learned routes         2 prefix(es) from 1 established peer(s)
                                    vrf-s2s    10.20.0.0/24        [20/0]   via 100.64.0.1      dev s2s_overlay0
  [PASS] OSPF neighbours            2 Full
  [PASS] OSPF-learned routes        2 prefix(es)
```

There is no VLAN table on this platform. 802.1Q subinterfaces are named
`ge<N>.<vlan>`, so the VLAN ID is the part after the dot, and a *directly
connected* segment is a route the kernel installed itself when the address was
configured (`proto kernel scope link`). A VLAN that is configured but has no
IPv4 subnet still appears, rather than vanishing from the inventory.

Two sources are read, because neither is sufficient alone:

| Source | Gives | Limitation |
|---|---|---|
| `show ip route` | the kernel FIB — what the box actually forwards on | once FRR installs a route the kernel labels it `proto zebra`; the origin protocol is lost |
| `vyos show ip route vrf all` | the FRR RIB, with each route attributed to the protocol that produced it (`C`/`S`/`B`/`O`) | an operational view of the routing container, not the forwarding plane |

`vrf all` is mandatory. BGP runs inside `vrf-s2s`, so the default VRF alone
looks like it has no BGP at all: `vyos show bgp summary` without `vrf all`
answers `% BGP instance not found`, which reads as "no BGP configured here"
when the site-to-site overlay is in fact established. Where the two sources
disagree the script says so rather than silently reconciling them; if the
FRR view fails to render, the protocol counts are reported as *not measured*
instead of as zero.

Long tables are capped at 25 lines per protocol — `--max-routes 0` lifts the
cap, `--max-routes N` sets it. Only the first next-hop of an ECMP route is
shown.

### Tunnels are reported in two layers

**Layer 1 — interface state (`NETWORK` section).** Which overlay interfaces
exist and are administratively up, listed by name. This is kernel fact and is
reported unconditionally.

**Layer 2 — evidence of a working tunnel (`TUNNELS` section).** An interface
reporting `UP` only means the device was created; it says nothing about whether
the tunnel is established. The two layers are deliberately independent, so the
baseline survives if any layer-2 signal is later dropped as unreliable:

```
  [PASS] Overlay interfaces         6 up (zia/zpa/wg/s2s)
                                    wg0 zia0 zia1 zpa0 wg_vpn_client0 s2s_overlay0
  [PASS] Tunnels passing traffic    3 of 6 moved data during this run
```

Layer 2 draws on:

- **Byte counters sampled at both ends of the session.** Direction matters: TX
  climbing while RX stays flat means the appliance is transmitting into the
  void. This costs no extra time — the run itself is the measurement window.
- **The control plane behind it** — BGP adjacency and prefix counts for
  site-to-site, established broker sessions for ZPA, IPsec SAs for ZIA.
  Policies present with zero SAs means configured-but-not-established.
- **The underlay flow in conntrack** — an `UNREPLIED` UDP/51820 flow is a
  WireGuard peer that is not answering.

`--no-tunnel-stats` drops the first of those three and the judgements built on
it (idle / one-way / RX errors). The control-plane and conntrack evidence still
runs, as does layer 1. It also removes both `show ip -s link` calls from the
session, so the run is two commands shorter.

### Provisional observations (`PROV`)

Some findings are real but their *meaning* is not yet agreed. These are tagged
`PROV`, are **never scored**, and never affect the exit code:

```
  [PROV] Tunnel one-way             transmitting but never received: wg0
                                    peer is not answering, OR provisioned-but-unused
                                    corroborate against the site design before treating this as a fault
```

Run with `--evidence` to append the unedited command output behind them. The
intent is to gather the same observations across several gateways and settle
which should become real checks and which should be dropped.

### Deliberate non-findings

Some things are reported as INFO rather than scored, because scoring them
would produce false alarms:

- **Container count is not fixed.** It is site-dependent — a gateway with no
  IPsec tunnel to ZIA has no `strongswan` container. The check is that every
  container present is `Up`.
- **`DHCP Server: inactive`** is normal unless the site serves DHCP.
- **DNS cache hit ratio is not scored.** The CoreDNS `miss` counter is
  emitted identically under all three cache categories, so any ratio derived
  from it overcounts misses. Pending confirmation of the counter semantics.
- **Unused `geN` ports are normally DOWN.**

## Troubleshooting

| Symptom | Cause |
|---|---|
| `could not be parsed` | prompt format differs on that build — rerun with `--keep-transcript` |
| `Authentication failed` | wrong password, or the account is not `admin` |
| `command "X" is not permitted for non-interactive execution` | you ran a `zcli` command directly rather than through this script — see below |
| partial run warning | session timed out; raise `-t` |

### A note on driving `zcli` yourself

`zcli` applies a **narrower allowlist to non-interactive execution**. Over
`ssh host "cmd"`, the commands `uptime`, `ps`, `top`, `ifconfig`, `clear`,
`help` and `zscaler-console` are all refused, and every workaround is closed
(`/proc/uptime` is outside the path sandbox, `docker stats` is blocked,
`journalctl --list-boots` is filtered). Non-interactive mode also runs one
command per connection — `;` does not chain.

This script sidesteps all of that by piping a command list into a single
interactive session, which is why it can report CPU, memory and load at all.

## License

[MIT](LICENSE) — © 2026 Andy Brown.

The licence governs reuse of this code. It is separate from, and does not
imply, any support relationship: as stated above, this is not a Zscaler
product and Zscaler does not support it.
