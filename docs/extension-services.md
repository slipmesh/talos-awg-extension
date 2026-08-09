# The `ext-awg` extension service

Since the `installer` republish that ships it, this extension carries two things, not one:

1. `amneziawg.ko`, as before - loaded via `machine.kernel.modules` in machine config (see the
   top-level README's "Usage").
2. `ext-awg` - a Talos "extension service" (a separate mechanism from the kernel module: a
   container spec at `rootfs/usr/local/etc/containers/awg.yaml`, run and supervised by `machined`
   as `talosctl service ext-awg`) that actually creates and configures AmneziaWG interfaces on the
   node - mesh links to other nodes, road-warrior client termination, or both. Without it, the
   module loads but nothing ever brings an interface up.

The `ext-awg` binary itself is built in the sibling repo `../talos-extensions` (a plain Rust
workspace, no Talos-packaging concerns of its own - see its README/AGENTS.md) and cross-compiled +
staged into this extension's rootfs by `make agents` (a new step `make extension` now depends on -
see the top-level README's "Usage" for the full target list). One extension, one version, one
`talosctl get extensions` - there's no separate `ext-awg` release to track.

## Why a second thing lives in the same extension

Talos nodes need mesh connectivity before kubelet/the Kubernetes API is reachable at all - in a
multi-site WAN mesh, the API server may only be reachable *through* this overlay, so bringing up
interfaces can't depend on the cluster already being up. `ext-awg` reads a config baked directly
into the node's machine config instead of watching any CRD, so it works from the very first boot,
independent of Kubernetes entirely. See `../talos-extensions/README.md` for the full design
rationale and `../talos-extensions/AGENTS.md` for the invariants a future change here must not
break (no Kubernetes dependency, no local key generation, no status files, etc).

## Config: one interface shape for both mesh and road-warrior use

There's no separate "mesh interface" vs "roadwarriors interface" type. Every `interfaces[]` entry
is the same shape; the difference is per-peer, driven by whether `allowed_ips` is set:

- **peer has no `allowed_ips`** -> full-tunnel default (`0.0.0.0/0` + `::/0`), no handshake
  polling, no kernel route ever installed for it. Use this for a node-to-node mesh link -
  reachability comes from whatever routing protocol runs over the tunnel (e.g. OSPFv3 over a
  link-local address), not a per-peer route.
- **peer has an explicit `allowed_ips`** -> exactly those CIDRs as AllowedIPs, handshake polled at
  1Hz, kernel route installed per CIDR while the handshake stays fresher than
  `handshake_stale_secs` (default 180s). Use this for a road-warrior client - the route's presence
  in the kernel *is* the "currently connected" signal, visible via `talosctl get routes` with no
  extra code anywhere.

One interface can mix both kinds of peer freely.

```yaml
interfaces:
  - name: mesh-a1b2c3d4          # any valid Linux ifname - no required prefix
    listen_port: 51820
    addresses: ["fe80::a1b2:c3d4/64"]   # CIDR, IPv4/IPv6 freely mixed, any count of either
    private_key: "...base64, this node's own..."
    obfuscation:                 # every field optional; omitted = kernel module default. This is
      jc: 4                      # the original nine (jc/jmin/jmax/s1/s2/h1-h4) - the full AmneziaWG
      jmin: 40                   # 3.0 set (s3/s4, i1-i5, header_protection_key, content padding,
      jmax: 70                   # rekey/keepalive/handshake timing) is also supported; see
      h1: 1                      # ../../talos-extensions/README.md for the complete field list.
      h2: 2
      h3: 3
      h4: 4
    peers:
      - public_key: "...peer's base64 public key..."
        endpoint: "203.0.113.7:51820"     # host:port, DNS or literal IP - omit for a NAT'd peer
        # no allowed_ips -> full-tunnel, untracked (mesh-style)
  - name: rw-eu
    listen_port: 51900
    addresses: ["10.99.0.1/24", "fd00:99::1/64"]
    private_key: "...base64, same value on every node that shares this identity..."
    handshake_stale_secs: 180    # optional, this is the default
    peers:
      - public_key: "...client's base64 public key..."
        allowed_ips: ["10.99.0.5/32"]     # tracked (roadwarriors-style)
```

**Private keys always come from this config - `ext-awg` never generates or persists one on the
node.** Whoever renders machine config is responsible for a node's own per-interface key, or the
same key across every node's config when a single shared identity is needed (e.g. a road-warrior
interface, so a roaming client sees one consistent server identity regardless of which node
answers).

## `machine.sysctls`: `net.ipv6.conf.default.keep_addr_on_down`

Without this, a statically assigned address (in particular an interface's IPv6 link-local, used
for an OSPFv3-style underlay) gets dropped every time the interface cycles down/up - e.g. a brief
reconnect - and doesn't come back until the next full reconcile reassigns it.

`ext-awg` does **not** set this itself: writing `net.ipv6.conf.<iface>.keep_addr_on_down` from
inside the extension service failed on a real node (the container isn't permitted to write
`/proc/sys` there), and even if it could, Talos's own `machine.sysctls` can't set a *per-interface*
sysctl for an interface that doesn't exist yet at boot - `mesh-*`/etc. interfaces are created later,
by `ext-awg` itself, well after Talos finishes applying `machine.sysctls` once at config-load time.

Instead, set the **default** template once - the kernel copies `net.ipv6.conf.default.*`
(`ipv6_devconf_dflt`) into every interface's own devconf at creation time (confirmed against
`net/ipv6/addrconf.c`), so this applies to every `ext-awg`-created interface automatically, with no
code in `ext-awg` needed at all:

```yaml
machine:
  sysctls:
    net.ipv6.conf.default.keep_addr_on_down: "1"
```

## Full machine config example

Multi-document machine config YAML - the `ExtensionServiceConfig` document's `name` must match the
service name (`awg`), and its `configFiles[].mountPath` must be exactly
`/etc/talos-extensions/awg.yaml` (the fixed path `ext-awg` reads - not configurable, see
`../talos-extensions/AGENTS.md`'s "no env vars, no CLI flags" invariant):

```yaml
# ... the rest of a normal v1alpha1 machine config ...
machine:
  kernel:
    modules:
      - name: amneziawg
  sysctls:
    net.ipv6.conf.default.keep_addr_on_down: "1"
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: awg
configFiles:
  - mountPath: /etc/talos-extensions/awg.yaml
    content: |
      interfaces:
        - name: mesh-a1b2c3d4
          listen_port: 51820
          addresses: ["fe80::a1b2:c3d4/64"]
          private_key: "...redacted..."
          peers:
            - public_key: "...redacted..."
              endpoint: "203.0.113.7:51820"
```

Applying this document (`talosctl apply-config`) is itself a config change Talos detects and reacts
to: `ext-awg` gets fully restarted with the new config, no reboot needed (confirmed against Talos
v1.13.7 source - `handleRestart()` in `internal/app/machined/pkg/controllers/runtime/
extension_service.go` restarts an extension service's container on any `ExtensionServiceConfig`
version change, independent of that service's own `restart:` policy).

## Verifying a build

Same spirit as the top-level README's "Verifying a build" for the kernel module - check the
artifact, don't trust a clean exit code:

```sh
file build/out-<arch>/rootfs/usr/local/lib/containers/awg/awg   # ELF ... statically linked, stripped
build/out-<arch>/rootfs/usr/local/lib/containers/awg/awg --help 2>&1 || true   # confirm it's the real binary, not a stub
```

## Verifying on a real node

- `talosctl -n <node> get extensions` - one extension (`amneziawg`), carrying both the module and
  `ext-awg`.
- `talosctl -n <node> service ext-awg` - state (should be `Running` once converged; `restart:
  always`, so any startup failure retries every 5s rather than sitting in `Failed`).
- `talosctl -n <node> logs ext-awg` and `talosctl -n <node> dmesg | grep awg` (the service runs
  with `logToConsole: true`, so its output also lands in the kernel console ring buffer
  independent of container-log retention).
- `talosctl -n <node> get links` / `get addresses` - every configured interface, visible via
  Talos's own native network resources, no extra code involved.
- `talosctl -n <node> get routes` - for road-warrior-style peers, which clients currently have a
  fresh-enough handshake to have an installed route (i.e. who's actually connected right now).
- Edit the `ExtensionServiceConfig` document (add/remove an interface or peer, or add/remove a
  peer's `allowed_ips` to flip it between full-tunnel and tracked), `talosctl apply-config`,
  confirm the change is live within seconds without a reboot.

## Local smoke test (before touching a real node)

Needs a Linux host/VM/container with the `amneziawg` module loaded and `CAP_NET_ADMIN`:

```sh
cd ../talos-extensions
cargo build -p awg
sudo mkdir -p /etc/talos-extensions
sudo cp <a hand-written awg.yaml> /etc/talos-extensions/awg.yaml
sudo ./target/debug/awg
# in another shell:
ip -d link show          # confirms interface(s), type amneziawg
wg show                  # or: ip link show type amneziawg; awg-tools if installed
ip route show            # for a tracked peer with a real handshake, confirms the installed route
```

Re-running after editing the config file (Ctrl-C, edit, re-run) exercises the same idempotency/GC
paths a real config-triggered restart would: existing interfaces/peers should converge without
disruption, and anything removed from the config should disappear.
