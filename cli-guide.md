# `zcli` — Zero Trust Branch CLI Reference

Command reference for **`zcli`**, the operator CLI of the Zscaler Zero Trust
Branch gateway (reached via `ssh admin@10.10.0.10`). Covers command syntax,
real examples, and gotchas — CLI only, not a device/architecture guide.

> **Scope & safety note:** Every command in the *Monitoring / Diagnostics / Info*
> sections below was executed against a live device and the output shown is
> real, except that identifying values — hostnames, site names, serials, MAC
> and IP addresses — have been replaced with documentation-safe placeholders.
> Commands that **change configuration or device state** (`config …`,
> `clear web-proxy`, everything under `run …`,
> `software activate|install|remove|mkdefault`, `dhcpcli -a set-debug-level`)
> were **documented from their `--help` text only and deliberately NOT
> executed.** They are clearly flagged with ⚠️.

---

> **New to `zcli`?** Jump to **§16 Common workflows (quick runbook)** for
> task-oriented command recipes, and **§17 Glossary** for terms that appear in
> command output. The companion **`command-tree.md`** shows the full command hierarchy.

---

## 1. Overview

### 1.1 What `zcli` is

`zcli` is the restricted operator CLI you land in when you SSH to the gateway as
`admin`. It is a **Cobra-style command tree** (top-level verbs → subcommands,
uniform `--help`) that wraps two kinds of commands:

- **Structured commands** — `show`, `config`, `run`, `software`, `dhcpcli`, `vyos`.
- **Safety-wrapped Linux tools** — `ip`, `iptables`, `ipset`, `conntrack`, `ps`,
  `top`, `tcpdump`, `journalctl`, `docker`, etc. These are read-only variants;
  mutating flags are blocked by the wrapper.

It is **not** a Unix shell — you can only run the whitelisted commands documented
here.

### 1.2 How to connect

```bash
ssh admin@10.10.0.10
```

- **Transport:** standard SSH. The server is `OpenSSH_8.2p1`; host key type is
  `ecdsa-sha2-nistp256`. Both `publickey` and `password` auth are offered.
- **User:** `admin` (password auth). This drops you directly into `zcli`, *not* a Unix shell.
- On first connect you'll accept the SSH host key.

### 1.3 Prompt conventions

```
branch-gw-01#
```

- The prompt is `<gateway-name>#`. The trailing **`#` does *not* mean a root
  Unix shell** — it is the restricted operator CLI. Under the hood the CLI runs
  specific whitelisted helpers via `sudo` (`/usr/local/bin/zcli-helper …`); you
  cannot run arbitrary shell commands.
- It is a **Cobra-style command tree**: top-level verbs, nested subcommands, and
  uniform help.

### 1.4 Getting help (`?` and `--help`)

Two equivalent mechanisms:

- **`?`** — context-sensitive help. Typing `?` at the prompt lists all
  top-level commands; `show ?` lists `show`'s subcommands, etc. (interactive —
  no Enter required).
- **`--help` / `-h`** — appended to any command path, prints the same help and
  returns to the prompt. This is the scripting-friendly form and is used
  throughout this document. `--help` is **non-mutating** even on dangerous
  commands (it prints usage without performing the action).

```
Use "[command] --help" for more information about a command.
```

### 1.5 Global output filtering (pipelines)

Every command supports an in-memory pipeline filter with `|`:

| Filter | Meaning |
|---|---|
| `\| grep [-i] <regex>` | keep only matching lines (`-i` = case-insensitive) |
| `\| include [-i] <regex>` | alias for `grep` |
| `\| exclude [-i] <regex>` | drop matching lines (inverse) |

```
branch-gw-01# show ip addr | include ge1
3: ge1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
```

> Only `grep`/`include`/`exclude` are available as pipe targets — there is no
> `head`/`tail`/`less` in the pipeline. Large outputs print in full; use the
> filters (or `journalctl -n`, `tail -n`) to trim.

### 1.6 Privileged / configuration modes (documented, not entered)

There is no separate "enable" mode — the `admin` CLI is already privileged. Two
areas can change the device and were **not** exercised:

- **`config …`** — the configuration hierarchy (`dns`, `network wan`, `ebond`,
  `web-proxy`). See §12.
- **`run support-shell`** — requests a **Zscaler-authorised root troubleshooting
  shell**. It generates a serial-bound one-time challenge; Zscaler Support
  returns a signed token that unlocks a time-limited root shell with full
  keystroke logging to `/var/log/support-shell-*.log`. This is the sanctioned
  break-glass path to a real root shell.
- **`zscaler-console`** — legacy menu-driven interactive configurator (§13).

---

## 2. Command map (top level)

| Command | Group | Mutating? |
|---|---|---|
| `show` | structured monitoring hierarchy | read-only |
| `arp`, `ifconfig`, `ethtool` | interface info | read-only |
| `conntrack` | connection tracking | read-only |
| `docker` | container inspection | read-only (restricted) |
| `ps`, `top`, `uptime` | process / resource | read-only |
| `journalctl`, `cat`, `tail`, `ls`, `grep`, `zcat`, `zgrep` | logs & files | read-only |
| `ping`, `traceroute`, `curl`, `tcpdump` | connectivity diagnostics | read-only |
| `dhcpcli` | DHCP server query | read-only actions only |
| `vyos` | VyOS routing operational commands | read-only (operational) |
| `software` | image management | `show`/`version` read-only; rest ⚠️ |
| `run` | lifecycle / operational actions | ⚠️ mutating |
| `config` | configuration hierarchy | ⚠️ mutating |
| `clear` | clear screen / ⚠️ `clear web-proxy` | mixed |
| `zscaler-console` | legacy UI | interactive |

---

## 3. System & appliance information

### `show version`
**Syntax:** `show version`
**Does:** prints the ZTB OS version and copyright/open-source notice.

```
branch-gw-01# show version
Zero Trust Branch OS, Version 8.1.2 (b226)
Copyright (c) 2019-2026 Zscaler, Inc.
...
https://github.com/airgap-io/open-source-usage
```

### `show appliance-status`
**Syntax:** `show appliance-status`
**Does:** one-shot health dashboard — gateway state, WAN/Internet/portal/analytics
reachability checks, per-service state, and the running container list.

```
branch-gw-01# show appliance-status
Gateway State : STANDALONE

WAN Connectivity:
Checking Default Gateway(10.10.0.1) via ge5...OK
Checking reachability to internet...Checking connectivity to 8.8.8.8...OK
Checking Management Portal reachability...OK
Checking Analytics connection...OK
Checking Debug Port reachability...SKIPPED (debug port not configured on this gateway)

Services Status:
Service                        State
MySQL Database                 active
System Logging                 active
Docker Engine                  active
Network Poller                 active
DHCP Server                    inactive
DHCP Events Uploader           active
Multicast DNS                  active
AD Integrator                  active
Data-stream Transformation     active
State Monitor                  active
Terminal Broker Client         active

Network Status:
CONTAINER ID   IMAGE                                  ...   NAMES
267aed635e74   zscaler/zpa-connector:latest.amd64     ...   branch_site_01
15bc61087936   ...                                    ...   dnsproxy_container
53fd56f77eef   ...                                    ...   strongswan
82b91db815a7   ...                                    ...   policy_container
c18f048ec00e   ...                                    ...   zeek
e6179809c47e   ...                                    ...   kinesis
37dc46e15b00   ...                                    ...   vyos_container
```

**Gotcha:** this is the single most useful "is the box healthy?" command. Note
`DHCP Server: inactive` is normal here (this gateway isn't serving DHCP).

### `show system services`
**Syntax:** `show system` → subcommand `services` → `show system services`
**Does:** just the service state table from `appliance-status`.

```
branch-gw-01# show system services
Services Status:
Service                        State
MySQL Database                 active
System Logging                 active
Docker Engine                  active
...
Terminal Broker Client         active
```

**Gotcha:** `show system` on its own only prints help — `services` is currently
its only subcommand.

### `show device-identifiers`
**Syntax:** `show device-identifiers`

```
branch-gw-01# show device-identifiers
Fetching device identifiers...
Device Model Type: NCA-1513E
System Serial Number: LR000000000000
TPM Certificate Serial Number: 0000000000
```

### `show configuration`
**Syntax:** `show configuration`
**Does:** compact summary of the gateway's site + WAN configuration.

```
branch-gw-01# show configuration
Site Configuration:
  Site Name                : branch-site-01
  Gateway Name             : branch-gw-01
  Management Portal        : https://tenant-a-api.goairgap.com
  Logging Level            : info
  System Service Tag       : LR000000000000

Network Configuration:
  WAN Interface            : ge5
  WAN IP Address           : 10.10.0.10/24
  WAN Default Gateway      : 10.10.0.1
  WAN Nameservers          : 1.1.1.1
  Web Proxy                : None
```

### `show ztp` — Zero Touch Provisioning
**Syntax:** `show ztp {activation-state | tpm-attest}`

- `show ztp activation-state` — queries the `ztpagent` HTTP API for activation/auth state.
- `show ztp tpm-attest` — runs `tpmutil attest` and prints TPM attestation output (read-only).

```
branch-gw-01# show ztp activation-state
ZTP Activation State:
=====================
Authentication State: false
ZTP Device: true
Serial Number: LR000000000000
TPM Serial Number: 0000000000
```

### `uptime`
**Syntax:** `uptime` — how long the gateway has run + load averages.

```
branch-gw-01# uptime
 21:03:07 up 4 days,  6:49,  1 user,  load average: 1.98, 1.90, 1.79
```

### `software show` / `software version`
**Syntax:** `software show` · `software version` (read-only)

```
branch-gw-01# software show
8.1.2+b226 active default
8.1.2.dev171 previous

branch-gw-01# software version
Zscaler Edge OS :
      Active Version: 8.1.2+b226
    Previous Version: 8.1.2.dev171
     Default Version: 8.1.2+b226
```

> The mutating `software` subcommands (`activate`, `install`, `mkdefault`,
> `remove`) are documented in §12.4 and were not run.

---

## 4. Interface & addressing info

### `show ip` — read-only `ip` wrapper
**Syntax:** `show ip [options] <object> [show [dev <interface>]]`
**Does:** the Linux `iproute2` `ip` tool, locked to read-only objects/options.
Modification verbs (`add`, `set`, `del`, `up`, `down`) are **blocked** — the help
explicitly says use `config network` instead.

Objects: `addr`, `route`, `link`, `rule`, `neigh`, `maddr`, `mroute`, `xfrm`, `netns`.
Useful options: `-br` (brief), `-s` (stats), `-d` (details), `-j -p` (pretty JSON),
`-4`/`-6`, `-N` (numeric), `-r` (resolve).

```
branch-gw-01# show ip route
default via 10.10.0.1 dev ge5 proto static metric 100 onlink
default via 10.10.200.1 dev ge6 proto static metric 200 onlink
10.10.0.0/24 dev ge5 proto kernel scope link src 10.10.0.10
10.10.66.0/24 dev ge2.66 proto kernel scope link src 10.10.66.1
10.10.67.0/24 dev ge2.67 proto kernel scope link src 10.10.67.1
100.64.1.1 dev wg_vpn_client0 scope link
203.0.113.0/26 dev docker0 proto kernel scope link src 203.0.113.1 dead linkdown
... (WireGuard s2s overlays, docker bridges, VLAN subinterfaces)
```

```
branch-gw-01# show ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
ge1              UP             00:00:5e:00:53:02 <BROADCAST,MULTICAST,UP,LOWER_UP>
ge5              UP             00:00:5e:00:53:03 <BROADCAST,MULTICAST,UP,LOWER_UP>
ge6              UP             00:00:5e:00:53:04 <BROADCAST,MULTICAST,UP,LOWER_UP>
ge2.66@ge2       UP             00:00:5e:00:53:07 <BROADCAST,MULTICAST,UP,LOWER_UP>
ztbmanagement    UP             00:00:5e:00:53:08 <NOARP,MASTER,UP,LOWER_UP>
wg_vpn_client0   UNKNOWN        ... <POINTOPOINT,NOARP,UP,LOWER_UP>
zpa0             UNKNOWN        ... <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP>
... (ge2 VLAN subifs .66/.67/.69/.70, ebond0/1, ipsec0/1, s2s_overlay0/1, docker0/br-*)
```

```
branch-gw-01# show ip neigh
10.10.0.1 dev ge5 lladdr 00:00:5e:00:53:05 REACHABLE
10.10.67.5 dev ge2.67 lladdr 10:c5:95:11:22:33 REACHABLE
10.10.200.1 dev ge6  FAILED
100.65.0.1 dev s2s_overlay1 lladdr 100.64.1.2 PERMANENT
fe80::290:bff:fec0:7861 dev ge5 lladdr 00:00:5e:00:53:01 STALE
```

`show ip addr` prints full per-interface addressing (v4/v6, MAC, MTU, altnames).

**More `show ip` objects (live):**

```
branch-gw-01# show ip rule
220:	from all lookup 220
900:	from all to 100.64.0.0/18 goto 1000
902:	from all iif s2s_overlay0 goto 2001
2010:	from all fwmark 0x600/0xfffffe00 lookup main suppress_prefixlength 0
2104:	from all fwmark 0x602 lookup zia_ipsec_rt
... (extensive fwmark-based policy routing — traffic is steered into VRFs/route
     tables by firewall marks for ZIA/ZPA/site-to-site segmentation)

branch-gw-01# show ip xfrm policy      # IPsec (strongSwan) policy database
src 0.0.0.0/0 dst 0.0.0.0/0
	dir out priority 399999
	tmpl src 10.10.0.10 dst 192.0.2.33
		proto esp spi 0x41a8dea4 reqid 1 mode tunnel
	if_id 0x2a
... (ESP tunnel to the ZIA service edge 192.0.2.33)

branch-gw-01# show ip maddr           # multicast group memberships (per iface)
2:	ge2
	link  01:00:5e:00:00:fb users 4    # mDNS
	inet  224.0.0.1
...
```

**Gotcha:** `show ip mroute` and `show ip netns` return **empty** on this
gateway (no multicast routing cache entries, no *named* network namespaces —
the per-container namespaces are anonymous). That's expected, not an error.

**Gotchas:**
- Interface naming: physical NICs are `ge1`–`ge6`; VLAN subinterfaces are
  `ge2.<vlan>`; overlays/tunnels are `wg_vpn_client*`, `s2s_overlay*`, `ipsec*`,
  `zpa0`; `ztbmanagement` is the internal management bridge.
- Prefer `show ip …` over `ifconfig`/`arp` for anything scripted — it's the most
  complete and has JSON output (`-j -p`).

### `ifconfig`
**Syntax:** `ifconfig [interface]`

```
branch-gw-01# ifconfig ge1
ge1: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet6 fe80::290:bff:fed7:92c3  prefixlen 64  scopeid 0x20<link>
        ether 00:00:5e:00:53:02  txqueuelen 1000  (Ethernet)
        RX packets 184280  bytes 11056800 (11.0 MB)
        TX packets 16  bytes 1516 (1.5 KB)
        device memory 0xdfc00000-dfc7ffff
```

**⚠️ Gotcha:** the help lists `ifconfig -s` (short summary) but the wrapper
**rejects it**: `Error: unknown shorthand flag: 's'`. Use `show ip -br link`
for a summary instead. `ifconfig` with no arg or `ifconfig <iface>` works.

### `ethtool`
**Syntax:** `ethtool [option] <interface>`
Read-only NIC query. Options: `-i` driver, `-S` stats, `-k` offloads, `-g` rings,
`-a` pause, `-c` coalescing, `-T` timestamping, `-x` RSS, `-l` channels.

```
branch-gw-01# ethtool ge1
Settings for ge1:
	Speed: 1000Mb/s
	Duplex: Full
	Port: Twisted Pair
	Auto-negotiation: on
	Link detected: yes

branch-gw-01# ethtool -i ge1
driver: igb
version: 5.15.0-181-generic
firmware-version: 3.25, 0x800005cf
bus-info: 0000:03:00.0
```

```
branch-gw-01# ethtool -S ge5          # NIC hardware counters (WAN interface)
NIC statistics:
     rx_packets: 27675532
     tx_packets: 26695352
     rx_bytes: 7597749002
     rx_errors: 0
     tx_errors: 0
     rx_dropped: 0
     ... (300+ driver counters — great for spotting drops/errors on a link)

branch-gw-01# ethtool -k ge1          # offload feature state
Features for ge1:
rx-checksumming: on
tcp-segmentation-offload: on
generic-receive-offload: on
...

branch-gw-01# ethtool -g ge1          # ring buffer sizes
Ring parameters for ge1:
Pre-set maximums:   RX: 4096   TX: 4096
Current hardware settings:   RX: 256   TX: 256
```

### `arp`
**Syntax:** `arp [-a] [-n] [-i <iface>] [host]` — read-only neighbor/ARP cache.

```
branch-gw-01# arp -an
? (10.10.0.200) at 00:00:5e:00:53:06 [ether] on ge5
? (10.10.67.5) at 10:c5:95:11:22:33 [ether] on ge2.67
? (10.10.0.1) at 00:00:5e:00:53:05 [ether] on ge5
? (10.10.200.1) at <incomplete> on ge6
? (100.64.0.2) at 64:40:80:d5 [ether] PERM on s2s_overlay0
```

---

## 5. Firewall, NAT, IP sets & connection tracking

### `show iptables`
**Syntax:** `show iptables [-t <table>] [-L|-S] [-n] [-v] [--line-numbers] [chain]`
**Does:** read-only view of host + container packet-filter rules. Modification
flags (`-A`, `-D`, `-I`, `-F`, `-P`) are blocked → use `config network`.

```
branch-gw-01# show iptables
Chain INPUT (policy DROP)
target     prot opt source               destination
ACCEPT     all  --  anywhere  anywhere   ctstate RELATED,ESTABLISHED
ACCEPT     all  --  127.0.0.0/8  anywhere
SGW_IPSEC_ZIA_RULES  all  --  anywhere  anywhere
SECURITY_RULES  all  --  anywhere  anywhere

Chain FORWARD (policy ACCEPT)
DOCKER-USER / DOCKER-FORWARD ...
Chain OUTPUT (policy ACCEPT)
S2SVPN_HA ... FIREWALL-OUTPUT ...
... (custom chains: SECURITY_RULES, SGW_IPSEC_ZIA_RULES, S2SVPN_HA, FIREWALL-OUTPUT)
```

```
branch-gw-01# show iptables -t nat
Chain PREROUTING (policy ACCEPT)
DOCKER / DNSPROXY_DNAT ...
Chain OUTPUT (policy ACCEPT)
DNAT  udp  --  anywhere  anywhere  udp dpt:domain owner UID match 998 to:127.0.0.1:1053
DNAT  tcp  --  anywhere  anywhere  tcp dpt:domain owner UID match 998 to:127.0.0.1:1053
Chain POSTROUTING (policy ACCEPT)
MASQUERADE  all  --  203.0.113.0/26  anywhere
MASQUERADE  all  --  anywhere  anywhere
```

**Note:** DNS from local processes (uid 998) is transparently DNAT-redirected to
the local DNS proxy on `127.0.0.1:1053`.

### `show ipset`
**Syntax:** `show ipset [list] [<set_name>] [terse]` — read-only. Create/add/del/
destroy/flush are blocked.

```
branch-gw-01# show ipset list zcc_ips
Name: zcc_ips
Type: hash:net
Number of entries: 4
Members:
10.10.150.252
10.10.150.253
100.70.0.0/16
10.10.150.224
```

Notable sets on this box: `zcc_ips`, `system-local-traffic-group`,
`wan_zone_ipset` (per-WAN-interface `0.0.0.0/0,geX`), plus numbered
policy sets. Use `show ipset list <name> terse` for just the header/metadata.

### `conntrack`
**Syntax:** `conntrack [-L | --list]` — read-only kernel connection tracking dump.

```
branch-gw-01# conntrack -L
tcp  6 431944 ESTABLISHED src=10.10.0.10 dst=192.0.2.241 sport=37384 dport=443 ... [ASSURED]
udp  17 18 src=10.10.0.10 dst=1.1.1.1 sport=46882 dport=53 ...
icmp 1 25 src=100.65.0.2 dst=100.65.0.1 type=8 ...
tcp  6 431994 ESTABLISHED src=127.0.0.1 dst=127.0.0.1 sport=40490 dport=8888 ... [ASSURED]
... (hundreds of flows; filter with '| include' e.g. conntrack -L | include ESTABLISHED)
```

**Gotcha:** output can be several hundred lines. Pipe it: `conntrack -L | include dport=443`.

---

## 6. DNS proxy

### `show dnsproxy`
**Syntax:** `show dnsproxy show {policies | metrics}`
**Does:** front-end to the DNS-proxy container's CLI — dumps active DNS policies
or CoreDNS cache metrics.

```
branch-gw-01# show dnsproxy show policies
+-----------+----------------------------+---------+-----------------+-----------+--------+...
| policy_id | policy_name                | rule_id | sequence_number | source_ips| domains|...
+-----------+----------------------------+---------+-----------------+-----------+--------+...
|       785 | Deny Guest ZPA Resolution  | ...
```

```
branch-gw-01# show dnsproxy show metrics
coredns_dnscache_entries{category="high"} 9
coredns_dnscache_lookups_total{category="high",result="hit"} 37094
coredns_dnscache_lookups_total{category="high",result="miss"} 18631
coredns_dnscache_non_cache_domains{category="num_domains"} 1
```

**⚠️ Gotcha:** `show dnsproxy policies` (without the inner `show`) just prints the
usage line `Usage: dnsproxy show [policies|metrics]`. The working form is
**`show dnsproxy show policies`** / **`show dnsproxy show metrics`** — note the
doubled `show`.

---

## 7. Routing engine — VyOS

### `vyos`
**Syntax:** `vyos <operational-command>`
**Does:** runs an **operational-mode** command inside the VyOS 1.4.4 container
(FRR-based routing). Supports `show`, `ping`, `traceroute`, etc.

```
branch-gw-01# vyos show ip route
Codes: K - kernel, C - connected, S - static, B - BGP, O - OSPF ...
K>* 0.0.0.0/0 [0/100] via 10.10.0.1, ge5 onlink, 4d06h25m
C>* 10.10.0.0/24 is directly connected, ge5, 4d06h25m
C>* 100.70.0.1/32 is directly connected, zpa0, 4d06h23m
C>* 10.10.66.0/24 is directly connected, ge2.66, 4d06h21m
... (connected VLANs, WireGuard s2s overlays, ZPA)
```

**Examples from help:** `vyos show interfaces`, `vyos show ip route`,
`vyos show bgp summary`.

**Gotchas:**
- `vyos show bgp summary` → `% BGP instance not found` (no BGP configured here).
- `vyos show interfaces` returned **empty** through the wrapper in testing — some
  VyOS op commands don't render via the wrapper; `show ip route` works well.
  Prefer the host-level `show ip …` for interface/addressing data.
- This runs *operational* (read-only) VyOS commands; VyOS *configure* mode is not
  exposed here.

---

## 8. DHCP server query — `dhcpcli`

**Syntax:** `dhcpcli -a <action> [filters]`
**Does:** queries the `airgap-dhcp` server database.
Read-only actions: `list-scopes`, `list-leases`, `get-leases`, `get-mastership`,
`list-reservations`, `list-dhcp-policies`, `get-debug-level`.
Optional filters: `-si/-ei` start/end IP, `-ms` MAC list, `-st` lease states
(`ALLOCATED,OFFERED,EXPIRED`), `-ea/-eb` expiry window.

```
branch-gw-01# dhcpcli -a get-mastership
Current mastership role is primary

branch-gw-01# dhcpcli -a list-dhcp-policies
DHCP Policies:
ID  Priority  Subnet  Filter Type  Filter Value  DHCP Options
1   15                                           {"15": {"Value": "\"example.org\"", "ValueType": "domain-name"}}

branch-gw-01# dhcpcli -a list-scopes
Scopes:                 # (empty — no scopes configured; DHCP server is inactive here)

branch-gw-01# dhcpcli -a list-leases
Leases:                 # (empty)

branch-gw-01# dhcpcli -a get-debug-level
Current debug level is 4 (Info)
```

**⚠️ Gotcha:** `dhcpcli -a set-debug-level -dl <0-6>` and `-a` role changes
(`-r primary|backup`) are **state-changing** — not exercised. Stick to the
`list-*`/`get-*` actions for read-only work.

---

## 9. Container inspection — `docker`

**Syntax:** `docker <subcommand>` — restricted, read-only. `run`, `exec`, `rm`,
`kill`, `start`, `stop` are **disabled**.
Allowed: `ps [-a|-q]`, `images`, `version`, `info`, `logs <container>`,
`inspect <container>` (use Tab-completion for container names).

```
branch-gw-01# docker ps
CONTAINER ID   IMAGE                                COMMAND               ... NAMES
267aed635e74   zscaler/zpa-connector:latest.amd64   "/start.sh"           ... branch_site_01
15bc61087936   ...                                  "... su dnsp…"        ... dnsproxy_container
53fd56f77eef   ...                                  "ipsec start --nofork"... strongswan
82b91db815a7   ...                                  "/root/co…"           ... policy_container
c18f048ec00e   ...                                  "entrypoint -f 'net …"... zeek
e6179809c47e   .../kinesis:1.2                      ...                   ... kinesis
37dc46e15b00   .../vyos:1.4.4-sagitta               "/sbin/init …"        ... vyos_container
```

```
branch-gw-01# docker version
Client/Server: Docker Engine - Community  Version: 28.1.1  API: 1.49
containerd 1.7.27 · runc v1.2.5

branch-gw-01# docker info    (excerpt)
 Containers: 7 (Running: 7)   Images: 7   Storage Driver: overlay2
 Kernel Version: 5.15.0-181-generic   Operating System: Ubuntu 20.04.1 LTS
 CPUs: 4   Total Memory: 31.3GiB
 Default Address Pools: Base: 203.0.113.0/26
```

```
branch-gw-01# docker logs dnsproxy_container
maxprocs: Leaving GOMAXPROCS=4: CPU quota undefined
[DNSCachePlugin] Starting!
[FQDNPlugin] Starting!
.:1053
CoreDNS-1.12.0
linux/amd64, go1.25.8
```

**Tip:** `docker logs <name>` is the way to dig into a specific data-plane
function (e.g. `docker logs dnsproxy_container` shows it's CoreDNS 1.12.0 on
`:1053`). Get exact container names from `docker ps`.

**⚠️ Gotcha:** although `docker --help` lists `inspect` as allowed, the wrapper
**rejected it** in testing: `docker inspect strongswan` →
`zcli-helper: docker: subcommand not permitted`. In practice, rely on
`docker ps`, `images`, `version`, `info`, and `logs`; if you need `inspect`,
it may require the `run support-shell` root path.

---

## 10. Process & resource monitoring

### `ps`
**Syntax:** `ps [aux | -ef | -u <user> | -p <pids> | --forest | -f]`

```
branch-gw-01# ps
USER   PID %CPU %MEM    VSZ   RSS TTY  STAT START   TIME COMMAND
root     1  0.0  0.0 171232 13220 ?   Ss   Jun26   5:58 /sbin/init
root     2  0.0  0.0      0     0 ?   S    Jun26   0:00 [kthreadd]
... (200+ processes; use ps aux or filter: ps aux | include java)
```

### `top`
**Syntax:** `top [-b] [-n <iters>] [-d <secs>] [-p <pids>] [-u <user>] [-H] [-i] [-c]`

```
branch-gw-01# top -b -n 1     (batch snapshot; excerpt)
top - 21:03:23 up 4 days,  6:49,  1 user,  load average: 1.98, 1.91, 1.79
Tasks: 222 total, 1 running, 221 sleeping
%Cpu(s):  5.6 us,  8.5 sy, 85.9 id
MiB Mem : 32054.0 total, 339.9 free, 3594.9 used, 28119.3 buff/cache
  PID USER   PR NI    VIRT    RES  SHR S %CPU %MEM     TIME+ COMMAND
31993 root   20  0 4094676 279116 18592 S 17.6  0.9 728:01 java
51672 998    20  0 1755216  54824 14748 S 11.8  0.2 777:58 image.bin
41704 root   20  0 2406244   1.0g 14908 S  5.9  3.3 357:04 zcc-client
```

**⚠️ Gotcha:** plain `top` launches the **interactive** full-screen viewer (press
`q` to quit). For scripted/one-shot use always run `top -b -n 1`.

---

## 11. Logs, files & search

All file commands are **sandboxed to diagnostic-readable areas** — primarily
`/var/log/` and `/etc/airgap/`. They will not read arbitrary paths.

### `journalctl`
**Syntax:** `journalctl [-u <svc>] [-n <lines>] [--since <time>] [-f] [-x] [-k] [-b]`
Output is **always non-paged**. Allowed services include `mysql`,
`terminal-broker-client`, `airgap-dhcp`.

```
branch-gw-01# journalctl -n 20    (excerpt)
-- Logs begin at Tue 2026-06-30 16:09:20 UTC, end at Tue 2026-06-30 21:04:05 UTC. --
Jun 30 21:04:03 ...--branch-gw-01 network-poller[1734]: wanmon record updated, wan_intf_name = ge6
Jun 30 21:04:04 ...--branch-gw-01 dns_cache_plugin[42366]: Adding Cache Entry for broker2-3.ams3.zpatwo.net.
Jun 30 21:04:05 ...--branch-gw-01 sudo[673852]: admin : COMMAND=/usr/local/bin/zcli-helper journal -n 20
```

Examples: `journalctl -u mysql`, `journalctl -n 50 -f`,
`journalctl -u terminal-broker-client --since "1 hour ago"`, `journalctl -k -b`.

### `cat` / `tail` / `ls` / `grep` / `zcat` / `zgrep`
Standard tools, restricted to the diagnostic areas.

```
branch-gw-01# ls -la /var/log/     (excerpt)
drwxrwxr-x 11 root syslog 24576 Jun 30 21:00 .
-rw-r----- 1 syslog adm  102729 Jun 30 21:03 auth.log
drwxr-xr-x 2 syslog adm    4096 Jun 30 20:36 appconnector
-rw-r--r-- 1 root root      882 Feb  3 airgap-dhcp-2026-02-03-...gz

branch-gw-01# ls -la /etc/airgap/  (excerpt)
-rw------- 1 root root 384 Jun 26 config.json.enc     # encrypted config
-rw------- 1 root root 185 Jun 26 activation.json
-rw-r--r-- 1 root root  35 Jun 26 gateway-config.yaml
drwxr-xr-x 3 root root      vyos/   dns_proxy/   policy_container/   web_proxy_cert/
```

- `cat <file>` / `tail [-f] [-n N] <file>` — view/follow log files.
- `grep [-i] [-A/-B/-C N] <pat> <file>` — search; `zgrep`/`zcat` for `.gz` rotated logs.

**Gotcha:** the main gateway config is stored **encrypted** (`config.json.enc`),
so `cat`-ing it isn't useful — use `show configuration` for the readable summary.

### `run view-pcap`
**Syntax:** `run view-pcap [filename] [decode_flags]`
**Does:** with no arg, lists pcap files in `/var/log/`; with a filename, decodes
it (permitted flags: `-v -vv -vvv -X -XX -x -xx -e -n -A -tttt`). *Listing is
read-only*; this was the only `run` subcommand safe to execute.

```
branch-gw-01# run view-pcap
Available pcap files in /var/log/:
  capture.pcap    3012 bytes  2026-06-25 11:31:59
```

---

## 12. Connectivity diagnostics

### `ping`
**Syntax:** `ping <host>` — ICMP echo, **capped at 4 requests**.

```
branch-gw-01# ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=116 time=11.0 ms
64 bytes from 8.8.8.8: icmp_seq=4 ttl=116 time=8.01 ms
--- 8.8.8.8 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3004ms
rtt min/avg/max/mdev = 8.012/9.542/11.001/1.065 ms
```

### `traceroute`
**Syntax:** `traceroute [options] <host>`
Options: `-I` (ICMP), `-m <max-hops>` (default 64), `-f <first-hop>`,
`-w <wait s>` (default 3), `-q <probes>` (default 3), `-p <port>`,
`--resolve-hostnames`, `-t <tos>`.

```
branch-gw-01# traceroute -m 5 -w 1 -q 1 8.8.8.8
traceroute to 8.8.8.8 (8.8.8.8), 5 hops max
  1   10.10.0.1  0.578ms
  2   192.0.2.178  1.750ms
  3   *
  4   *
```

**Gotcha:** default wait is 3s/hop with 3 probes and up to 64 hops — a trace to
an unreachable host can be slow. Bound it with `-m`, `-w`, `-q` as above.

### `curl`
**Syntax:** `curl [-v] <url>` — HTTP/HTTPS connectivity/TLS test. `-v` shows the
connection + certificate details. (Not executed against an external endpoint in
this run; use e.g. `curl -v https://tenant-a-api.goairgap.com` to test
portal reachability.)

### `tcpdump`
**Syntax:** `tcpdump [flags] [filter expression]`
**Does:** live packet capture, or save to a PCAP under `/var/log/` with `-o` for
later `run view-pcap`.
Options: `-i <iface>` (default `any`), `-t <seconds>` (capture duration, default 60),
`-o <file>`; decode flags `-v/-vv/-vvv`, `-X/-XX`, `-x/-xx`, `-A`, `-e`, `-n`, `-tttt`.

```
tcpdump -i ge1 -vn port 80                 # live, verbose, numeric
tcpdump -o capture.pcap -t 30 -i any port 443   # 30s capture to file
```

> **Not executed** in this run — a live capture blocks up to its `-t` timeout and
> generates load. The syntax above is from the device's own help.

---

## 13. ⚠️ Configuration commands — documented, NOT executed

These **change device configuration**. Listed for completeness; none were run.
`--help` on any of them is safe (prints usage only).

### `config` hierarchy
`config {dns | network wan | ebond | web-proxy}`

| Command | Syntax | Purpose |
|---|---|---|
| `config dns` | `config dns <dns1> [dns2] …` (or `-n a,b`) | set system resolvers (writes `/etc/resolv.conf`). e.g. `config dns 8.8.8.8 8.8.4.4` |
| `config network wan` | `config network wan <iface> <dhcp\|static> [ip gw dns]` | WAN config. e.g. `config network wan ge7 static 192.168.1.10/24 192.168.1.1 8.8.8.8` |
| `config ebond` | `config ebond <name> <m1,m2,…>` | LACP 802.3ad bond. e.g. `config ebond ebond0 ge1,ge2`. **Only allowed before gateway activation.** |
| `config web-proxy` | `config web-proxy <proxy-url> [-s <htpdate-server>]` | corporate proxy for egress. e.g. `config web-proxy http://user:pass@proxy:8080` |

### `clear web-proxy` ⚠️
`clear web-proxy` — removes the web-proxy configuration. (`clear` on its own just
clears the screen and is harmless.)

### `run` — lifecycle / operational actions ⚠️
`run <action>`:

| Action | Effect |
|---|---|
| `run restart [service]` | restart one whitelisted service (`mysql`, `rsyslog`, `docker`, `airgap-dhcp`, `securedhcp-relay`, `terminal-broker-client`, `ztpagent`) or, with no arg, **master-restart all** routing/diagnostic services |
| `run reboot` | reboot the gateway |
| `run shutdown` | power off the gateway |
| `run restart` (no svc) | sequential restart of all container routing engines |
| `run change-password` | change the `admin` password |
| `run tech-support` | collect a tech-support bundle |
| `run support-shell` | request Zscaler-signed, time-limited, keystroke-logged **root shell** (break-glass) |
| `run clear-pcap` | delete pcap files from `/var/log` |
| `run upload-pcap [file]` | upload pcap(s) to S3 |
| `run reset-appliance-state` | reset appliance state |
| `run factory-reset` | **factory reset** the gateway |
| `run decommission` | **decommission** the gateway |

### `software` — image management ⚠️
| Command | Effect |
|---|---|
| `software install <bundle>` | install an upgrade bundle copied to `/home/admin` via scp/sftp |
| `software activate <version>` | activate an image — **REBOOTS the gateway** |
| `software mkdefault <version>` | set default boot image (no reboot) |
| `software remove <version>` | remove a non-active, non-default image |

### `dhcpcli` mutating actions ⚠️
`dhcpcli -a set-debug-level -dl <0-6>` and mastership role changes (`-r primary|backup`).

---

## 14. `zscaler-console` (legacy UI)

**Syntax:** `zscaler-console`
Launches the legacy Airgap menu-driven interactive configuration tool. Not
launched in this run (it takes over the terminal). Mentioned for completeness.

---

## 15. Quick-reference cheat sheet

**Info / status**
| Command | Description |
|---|---|
| `show version` | ZTB OS version |
| `show appliance-status` | full health dashboard (WAN/portal/services/containers) |
| `show system services` | service state table |
| `show device-identifiers` | model, serial, TPM serial |
| `show configuration` | site + WAN config summary |
| `show ztp activation-state` | ZTP/activation state |
| `show ztp tpm-attest` | TPM attestation |
| `uptime` | uptime + load |
| `software show` / `software version` | installed image versions |

**Interfaces / addressing**
| Command | Description |
|---|---|
| `show ip route` | routing table |
| `show ip -br link` | brief link/state summary |
| `show ip addr` | full per-interface addressing |
| `show ip neigh` | neighbor/ARP table |
| `arp -an` | ARP cache (numeric) |
| `ifconfig <iface>` | interface counters/details |
| `ethtool <iface>` / `ethtool -i <iface>` | link settings / driver info |

**Firewall / NAT / sets / flows**
| Command | Description |
|---|---|
| `show iptables [-t nat]` | packet-filter / NAT rules |
| `show ipset list [name] [terse]` | IP sets |
| `conntrack -L` | connection tracking table |

**Services / data-plane**
| Command | Description |
|---|---|
| `show dnsproxy show policies` | DNS proxy policies |
| `show dnsproxy show metrics` | DNS cache metrics |
| `vyos show ip route` | VyOS/FRR routing table |
| `dhcpcli -a list-leases` | DHCP leases |
| `dhcpcli -a get-mastership` | DHCP HA role |
| `docker ps` / `docker logs <c>` / `docker inspect <c>` | container state / logs |

**Host / logs / files**
| Command | Description |
|---|---|
| `ps aux` | process list |
| `top -b -n 1` | resource snapshot (non-interactive) |
| `journalctl -u <svc> -n <N>` | service logs |
| `ls -la /var/log/` | list log dir |
| `cat` / `tail -f` / `grep` / `zgrep` | view/search logs (sandboxed) |
| `run view-pcap` | list saved pcaps |

**Diagnostics**
| Command | Description |
|---|---|
| `ping <host>` | ICMP test (max 4) |
| `traceroute -m 5 -w 1 -q 1 <host>` | path trace (bounded) |
| `curl -v <url>` | HTTP/TLS reachability test |
| `tcpdump -i <iface> -t <s> -o <file>` | capture (live/to pcap) |

**Global**
| Feature | Usage |
|---|---|
| Help | `?` (interactive) or `<cmd> --help` |
| Filter output | `<cmd> \| include <re>` · `\| exclude <re>` · `\| grep [-i] <re>` |
| JSON (ip) | `show ip -j -p addr` |

**⚠️ Mutating — use with care (not run here):**
`config dns` · `config network wan` · `config ebond` · `config web-proxy` ·
`clear web-proxy` · `run restart|reboot|shutdown|factory-reset|decommission|reset-appliance-state|change-password|tech-support|support-shell|clear-pcap|upload-pcap` ·
`software install|activate|mkdefault|remove` · `dhcpcli -a set-debug-level` ·
`zscaler-console`

---
## 16. Common workflows (quick runbook)

Task-oriented recipes for day-to-day operations. All commands here are read-only.

### 16.1 "Is the branch healthy?" — 30-second check
```
show appliance-status      # WAN/Internet/portal/analytics + service + container state
show system services       # just the service table, if you only need that
uptime                     # load + how long it's been up
```
Look for: `Gateway State`, all WAN/reachability checks `OK`, services `active`
(note `DHCP Server: inactive` is normal unless this site serves DHCP), and 7
containers `Up`.

### 16.2 WAN / Internet connectivity problems
```
show configuration                 # confirm WAN iface, IP, gateway, DNS
show ip route                      # are both default routes present? (ge5 metric 100, ge6 200)
show ip -br link                   # is the WAN link UP?
ping 8.8.8.8                       # basic Internet reachability (4 packets)
traceroute -m 10 -w 1 8.8.8.8      # where does the path break?
ethtool ge5                        # link speed/duplex/carrier
ethtool -S ge5                     # rx/tx errors, drops
show ip neigh                      # is the next-hop gateway resolving (REACHABLE)?
```

### 16.3 DNS issues
```
show dnsproxy show metrics         # cache hit/miss — is the proxy serving?
show dnsproxy show policies        # which DNS policy might be blocking a domain
docker logs dnsproxy_container     # CoreDNS startup / errors
show iptables -t nat | include 1053   # confirm DNS is being DNAT'd to the proxy
```

### 16.4 Routing / segmentation / VPN
```
show ip route                      # kernel routing table
vyos show ip route                 # FRR view (codes, uptime, protocol)
show ip rule                       # fwmark-based policy routing (ZIA/ZPA/s2s steering)
show ip xfrm policy                # IPsec tunnels to the ZIA edge
conntrack -L | include ESTABLISHED # live flows
show ipset list wan_zone_ipset     # WAN zone membership
```

### 16.5 Firewall / "why is traffic blocked?"
```
show iptables                      # filter table (INPUT default DROP + custom chains)
show iptables -t nat               # DNAT/MASQUERADE
show ipset list                    # named sets referenced by rules
```

### 16.6 Performance / load
```
top -b -n 1                        # CPU/mem snapshot (top consumers)
ps aux | include java              # find a specific process
uptime                             # load averages
```

### 16.7 Logs & packet capture
```
journalctl -u terminal-broker-client -n 100
journalctl -k -b                   # kernel log, this boot
tail -f /var/log/syslog            # follow syslog (Ctrl-C to stop)
run view-pcap                      # list saved captures
# to capture (writes a file, read-only to traffic):
tcpdump -o wan.pcap -t 30 -i ge5 host 8.8.8.8
run view-pcap wan.pcap -n          # decode it afterwards
```

### 16.8 Version / image status
```
show version
software version
software show
```

---

## 17. Glossary

| Term | Meaning |
|---|---|
| **ZTB** | Zero Trust Branch — Zscaler's branch gateway appliance (this device). |
| **ZIA** | Zscaler Internet Access — cloud secure web gateway for Internet-bound traffic (reached here over an IPsec/ESP tunnel to the service edge). |
| **ZPA** | Zscaler Private Access — zero-trust access to private apps; provided by the `zpa-connector` container via the `zpa0` overlay. |
| **ZTP** | Zero Touch Provisioning — automated onboarding/activation of the gateway against the cloud (`ztpagent`). |
| **Gateway / Site** | Logical names for this appliance (`branch-gw-01`) and its location (`branch-site-01`). |
| **STANDALONE** | Gateway HA state — running solo (not in an HA pair). |
| **ebond** | An LACP (802.3ad) link-aggregation bond of two+ physical NICs (`config ebond`). |
| **VRF** | Virtual Routing & Forwarding — separate routing tables (e.g. `vrf-s2s`) used to isolate traffic classes. |
| **fwmark** | A firewall mark set by netfilter and matched by `ip rule` to steer packets into a specific route table/VRF. |
| **xfrm** | The Linux IPsec framework (policy/state); `show ip xfrm policy` shows tunnels. |
| **conntrack** | Kernel connection-tracking table (stateful flow records). |
| **ipset** | Named kernel sets of IPs/nets/ports referenced by iptables rules. |
| **DNAT / MASQUERADE** | NAT operations — destination rewrite (e.g. DNS → local proxy) / source NAT for egress. |
| **CoreDNS** | The DNS server powering `dnsproxy_container` (listens on `127.0.0.1:1053`). |
| **VyOS / FRR** | Open-source router OS (VyOS 1.4.4) running in a container; FRRouting is its routing daemon suite (static/BGP/OSPF). |
| **strongSwan** | Open-source IPsec daemon (the `strongswan` container) providing site-to-site VPN. |
| **Zeek** | Network security monitor performing traffic analysis (the `zeek` container). |
| **Kinesis** | AWS streaming service; the `kinesis` container ships telemetry/logs to the cloud. |
| **HTPDate** | HTTP-based time sync used when a corporate web proxy is configured (`config web-proxy -s`). |
| **TPM** | Trusted Platform Module — hardware security chip; used for device attestation (`show ztp tpm-attest`). |
| **ge1…ge6** | Physical gigabit interfaces. `ge2.NN` = 802.1Q VLAN sub-interface. |
| **zcli-helper** | The internal privileged helper the CLI shells out to (via sudo) to run whitelisted actions. |

---

*Documentation captured via a read-only SSH exploration. Mutating commands were
mapped from their built-in `--help` and intentionally not executed against the
live appliance.*
