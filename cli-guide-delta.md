# `cli-guide.md` — verification delta

**Verified:** 2026-09-16 · **Against:** `lab-gw-02` at `10.20.1.1`, ZTB OS **8.1.2-P1 (b323)**
**Guide documents:** `branch-gw-01` at `10.10.0.10`, ZTB OS **8.1.2 (b226)**

This file records where `cli-guide.md` diverges from a live appliance. The original
guide is unmodified. Every command below was executed read-only; nothing mutating
was run.

> **The two appliances are different devices on different builds.** That is useful
> rather than a problem — it separates *site-specific values* (which the guide
> sometimes presents as expected values) from *genuine CLI behaviour*.

| | Guide | Verified live |
|---|---|---|
| Gateway / Site | `branch-gw-01` / branch-site-01 | `lab-gw-02` / lab-site-02 |
| Platform | NCA-1513E appliance, TPM present | Virtual machine, no TPM, no serial |
| OS | 8.1.2 (b226) | 8.1.2-P1 (b323) |
| WAN | `ge5`, 10.10.0.10/24 | `ge2`, 10.20.0.7/28 |
| Portal | tenant-a-api.goairgap.com | tenant-b-api.goairgap.com |
| Containers | 7, incl. `strongswan` | 6, no `strongswan`, no IPsec |

---

## 1. NEW — the non-interactive allowlist (undocumented)

The guide describes one allowlist. There are **two**. When a command is passed as an
SSH argument (`ssh admin@host "command"`) rather than typed at the prompt, zcli
applies a second, narrower filter:

```
$ ssh admin@10.20.1.1 "uptime"
zcli: command "uptime" is not permitted for non-interactive execution
```

**Refused non-interactively:** `uptime` · `ps` · `top` · `ifconfig` · `clear` ·
`help` · `zscaler-console`

**Permitted non-interactively:** everything else tested — all of `show *`,
`software show|version`, `docker`, `vyos`, `dhcpcli`, `journalctl`, `conntrack`,
`ethtool`, `arp`, `ping`, `traceroute`, `cat`/`tail`/`grep`/`ls`, `run view-pcap`.

### Consequence: no CPU / memory / load data in non-interactive mode

Every fallback route is also sealed:

| Attempt | Result |
|---|---|
| `cat /proc/uptime` | `Error: path "/proc/uptime" is outside the diagnostic-readable area` |
| `cat /proc/loadavg` | same |
| `docker stats --no-stream` | `zcli-helper: docker: subcommand not permitted` |
| `journalctl --list-boots` | `zcli-helper: journal: flag "--list-boots" not permitted` |

### Consequence: one command per connection

`;` and newlines do **not** chain. `ssh host "show version; show configuration"`
passes the whole string to `show` as arguments and prints `show`'s help.

### Workaround: pipe a command list into one interactive session

This lifts both limits — one login, and `uptime`/`top`/`ps` work again:

```bash
printf 'show version\nuptime\nexit\n' | ssh -tt admin@HOST \
  | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
  | tr '\r' '\n' | sed -e 's/.*\x08//' | cat -s
```

The scrub removes ANSI sequences and the per-keystroke echo redraw. What survives is
clean, with the `GATEWAY# <command>` echo as a natural block delimiter for parsing.
This is the mechanism `ztb-health.sh` is built on.

---

## 2. NEW — `show zpa` is missing from the guide entirely

A whole command group, and the richest health source on the box:

```
show zpa appsegments   Show ZPA App Segments List
show zpa certificates  Show ZPA Certificates Information
show zpa config        Show ZPA Config
show zpa fqdn          Show ZPA FQDNs
show zpa ip            Show ZPA IP address
```

`show zpa config` returns broker, `customer_id`, `orgid`, `sni`, `zia_cloud`, `zpa_cloud`.

`show zpa certificates` returns **expiry dates** — directly usable for expiry alerting:

```
bc.crt:
  common_name: 173042097624037112985521377468671861310null
  expiry: Monday, June 21, 2027 at 11:47:52 AM UTC
  issuer: Zscaler
```

`show zpa ip` / `fqdn` / `appsegments` list what the connector currently publishes
(27 IPs, 25 FQDNs, 55 segments on this box). An empty list is a meaningful signal
that the connector has not synced.

The full `show` subcommand list on b323 is: `appliance-status`, `configuration`,
`device-identifiers`, `dnsproxy`, `ip`, `ipset`, `iptables`, `system`, `version`,
`zpa`, `ztp`.

---

## 3. Corrections to existing content

### §9 — `docker inspect` now works
The guide (§9, ⚠️ Gotcha) says the wrapper rejects it with
`zcli-helper: docker: subcommand not permitted`. On b323 `docker inspect vyos_container`
returns JSON normally. The advice to fall back to `run support-shell` is no longer needed.

*(`docker stats` genuinely is still blocked, so the wrapper is still selective.)*

### §7 — `vyos show interfaces` now works
The guide says it "returned empty through the wrapper in testing". On b323 it renders:

```
Codes: S - State, L - Link, u - Up, D - Down, A - Admin Down
```

### §6 — `show dnsproxy show policies` output format changed
The guide shows an ASCII-bordered table (`+-----------+---...`). On b323 the output is
**tab-separated** with a plain header row. Anything parsing the bordered format breaks.

```
policy_id	policy_name	rule_id	sequence_number	source_ips	domains	action
```

### §6 — `show dnsproxy show metrics` values can be in scientific notation
Not mentioned in the guide, and it breaks shell arithmetic:

```
coredns_dnscache_lookups_total{category="high",result="miss"} 1.391742e+06
```

Also note the `miss` counter is emitted **identically under every cache category**
(`high`, `low`, `medium`). Summing across categories triple-counts misses, so any
naive hit-rate is wrong. *Needs engineering confirmation of the counter semantics.*

### §7 — BGP *is* configured, just inside a VRF

The guide says `vyos show bgp summary` returns `% BGP instance not found` and
concludes "no BGP configured here". True only of the default VRF. BGP runs in
`vrf-s2s` and carries the site-to-site overlay:

```
branch-gw-01# vyos show bgp vrf all summary
IPv4 Unicast Summary (VRF vrf-s2s):
BGP router identifier 100.64.2.1, local AS number 266 vrf-id 27
Neighbor        V   AS  MsgRcvd MsgSent  Up/Down  State/PfxRcd  PfxSnt
100.64.0.1  4  268     2976    2976  2d01h31m            1       6
```

This is the authoritative health signal for an S2S overlay — a non-numeric
`State/PfxRcd` (`Idle`/`Active`/`Connect`) means the adjacency is down.

### §4 — interface `UP` does not mean a tunnel is established

Worth stating explicitly, since the guide's interface section invites the
assumption. On the verified gateway `wg0` reports `UP` while having received
**zero bytes since boot** and still transmitting. Useful signals instead:

| Signal | Command |
|---|---|
| directional byte counters | `show ip -s link` (sample twice) |
| IPsec SAs (not just policy) | `show ip xfrm state` |
| S2S adjacency | `vyos show bgp vrf all summary` |
| ZPA connector attached | `conntrack -L \| include dport=443` |
| WireGuard peer answering | `conntrack -L \| include 51820` → `[UNREPLIED]` |

Note `journalctl` rejects the pipeline filter (`zcli-helper: journal: flag "|"
not permitted`), unlike every other command — filter its output locally.

The appliance also keeps an internal tunnel-status API that `zcli` does not
expose; the network-poller logs `publish_tunnel_metrics: No tunnel status
found for tunnel type GRE / IPSec`. Worth asking whether it can be surfaced.

### §3 / §16.1 — "7 containers" is not a health criterion
The guide's §16.1 runbook says to look for "7 containers `Up`". That is site-specific.
This gateway runs **6** and is healthy: with no IPsec tunnel to ZIA there is no
`strongswan` container, and `show ip xfrm policy` is correspondingly empty.
Check that all containers are `Up`, not that there is a particular number.

### §1.2 / §1.3 — connection details are site-specific
`ssh admin@10.10.0.10` and the `branch-gw-01#` prompt are examples, not constants.

---

## 4. Confirmed still accurate

- Pipeline filters `| grep [-i]` / `| include` / `| exclude`; no `head`/`tail`/`less`.
- `show ip` object set and read-only enforcement; `-br`, `-j -p`, `-s` options.
- `show ip mroute` and `show ip netns` return empty (expected, not an error).
- `show dnsproxy policies` without the doubled `show` prints only the usage line.
- `vyos show bgp summary` → `% BGP instance not found` (no BGP configured).
- File tools sandboxed to `/var/log/` and `/etc/airgap/`; paths outside are refused.
- `ping` capped at 4 packets.
- `curl` accepts only `-v` and a URL — `-s` and `-o` are rejected
  (`unknown shorthand flag: 's'`).
- `show iptables` INPUT policy is `DROP`; `ipset`, `conntrack`, `dhcpcli` read-only
  actions, `journalctl`, and `run view-pcap` all behave as documented.
- The main config really is encrypted (`config.json.enc`); use `show configuration`.

---

## 5. Observations needing engineering validation

Not guide errors — behaviour seen on the live box that I cannot interpret confidently.

1. **`software show` default ≠ active.** Active is `8.1.2-P1+b323`, default is
   `8.1.2+b257`. A reboot would silently start the older image. `ztb-health.sh`
   scores this **FAIL**; confirm that is the right severity.
2. **`ZTP Authentication State: false`** on *both* appliances, including the healthy
   one in the guide. Either it is normal post-activation, or both boxes share a
   condition. Scored **WARN** pending an answer.
3. **Management interface naming.** The login banner reports `Management If : ge3`,
   but `ge3` is `DOWN` and the management address `10.20.1.1/29` lives on `lo0`.
   Scored **INFO** only.
4. **The login banner carries fields `show configuration` does not** — notably
   `Management If`. Worth documenting as a data source.
5. **`wg0` transmits but has never received.** Zero RX bytes since boot, TX
   still climbing, and its underlay flow to `192.0.2.124:51820` is
   `[UNREPLIED]`. Addressed from `198.51.100.0/24` (TEST-NET-2), which suggests
   an unprovisioned default rather than a fault. Reported **PROV**, not scored.
6. **`wg_vpn_client0` shows ~214k RX errors**, roughly 19% of packets received,
   while otherwise passing traffic normally. May be expected for that
   encapsulation. Reported **PROV**, not scored.
