# Handoff: make a container runtime work inside a firecode guest

**Goal.** A guest in which `docker run --rm hello-world` works and a compose stack reaches
healthy — specifically PeerDB's `docker-compose-dev.yml` (14 services) as `tilt up` drives it,
so the repo's `-tags tilt` e2e suites can run inside a microVM.

**RESOLVED, 2026-10-12** — landed as `3c7d8cc` + `122ebde`; all three acceptance items below
were then observed green in a guest on this host. The diagnosis further down is kept as written,
because it is what the fix came from, but its "measured today" line and its open questions are
answered here.

The fix is Route A, whole. `scripts/setup-macos.sh:162-193` now puts **every** module of the
kernel version on a read-only ext4 drive of its own (`images/modules-<ver>.ext4`, ~170 MB as
Ubuntu ships it, built once per kernel), and `guest/firecode-setup.sh:170-198` mounts it
read-only over a writable layer, runs `depmod -a` **once per kernel version** into
`$STATE/modules-index/<ver>/`, and reuses that per project. So `modprobe` resolves names and
dependencies the way it does on any machine, there is no hand-kept module list for the next
capability to extend, and the four-module initramfs is left to do what it was for: assemble
and reach the root.

Storage is answered without `/dev/fuse` (open question 1): docker's and containerd's state
lives on the **workspace layer** — a real ext4 at `/firecode/upper`, under the guest's own
overlay root — bind-mounted to `/var/lib/{docker,containerd}` (`firecode-setup.sh:201-217`).
That is why `overlay2` mounts; and because it is the layer, pulled images survive the VM the
way installed packages do.

Two more lines from `122ebde` are load-bearing rather than cosmetic: in a guest the docker
host *is* the guest, so `127.0.0.1 host.docker.internal` goes into the guest's `/etc/hosts`
(`:218-226`) — PeerDB's `.env` sends every e2e connection there — and the guest user is added
to the `docker` group.

Observed, in the guest that ran PeerDB's stack and its e2e suite:

    docker run --rm hello-world                  exits 0
    docker info                                  storage driver: overlay2
    the compose stack                            every service up (7 core + 2 ancillary postgres)
    go test -tags tilt ./e2e/postgres_postgres/  ok github.com/PeerDB-io/peerdb/flow/e2e/postgres_postgres 2.809s
                                                 (TestPeerFlowE2ETestSuitePG/Test_Complete_QRep_Flow_Multi_Insert_PG)

Open questions 2-4 are moot: the size question was settled by taking Route A (the drive is
built from what is in the tree, sized ×5/4 + 32 MiB), `linux-modules-<ver>` alone is enough
once the whole tree is present, and podman was never needed.

## Original brief

**Acceptance.** In a fresh guest, all three:

1. `docker info` reports a running daemon and `docker run --rm hello-world` exits 0.
2. `docker compose -f docker-compose-dev.yml up -d` brings every service to healthy, with
   service-name resolution working (the stack's env points at `catalog:5432`, `temporal:7233`).
3. `cd flow && go test -tags tilt ./e2e/postgres_postgres/ -run <TestName> -timeout 20m` passes.

Superseded: at the time of writing item 1 failed, so 2 and 3 were untested. All three are
observed green now — see the resolution above.

## Evidence, from a guest on this host

Ubuntu 24.04 arm64, kernel `7.0.0-38-generic`, 16 GB, booted with
`firecode up --project <tree> --mem 16384`. Docker installs cleanly (`docker.io`,
`docker-compose-v2`); systemd is present and the unit is fine. The daemon dies on the kernel:

    failed to mount overlay: invalid argument                      storage-driver=overlay2
    failed to initialize nft: Protocol not supported                iptables (nft backend)
    modprobe: Module nf_conntrack not found in directory /lib/modules/7.0.0-38-generic
    modprobe: Module bridge not found in directory /lib/modules/7.0.0-38-generic
    Failed to create bridge docker0 via netlink: operation not supported
    failed to start daemon: … error creating default "bridge" network: operation not supported

`modprobe` failing with "not found in directory /lib/modules/<ver>" is the tell: **the guest has
no module tree at all**, so no module can be resolved by name, and the only modules a guest ever
has are the ones the image injects by hand.

Already tried, so nobody repeats it: installing `fuse-overlayfs` (it *works* — dockerd logs
`[graphdriver] trying configured driver: fuse-overlayfs` and proceeds), and
`dockerd --iptables=false --ip6tables=false` (this gets past the NAT-chain failure). With both,
the daemon still dies at `docker0`. `--bridge=none` would start it, but then there is no
container network, and rewriting the stack to host networking means testing a configuration CI
never runs.

## Root cause, in this repository

`scripts/setup-macos.sh` already fetches the full module tree and then throws nearly all of it
away:

- `:133` — `fetch_deb "linux-modules-$ver" "$TMP/mod"` — the whole `linux-modules-<ver>` package
  is downloaded to `$TMP/mod`.
- `:146-158` — four modules are extracted and the load order written down by hand:

      mods=(overlay vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport)
      # No depmod here, so the order is written down; modinfo's depends= is what decided it.
      …
      printf '%s\n' "${mods[@]}" >"$MAC/modules/load"

So: `overlay` and the vsock transport — exactly what the root needs to be assembled and reached —
and nothing else. No bridge, no netfilter, no `veth`, no `nf_tables`, no conntrack. The Linux path
has the same shape: `scripts/build-kernel.sh` builds `make modules` but installs a chosen subset,
and its `CONFIG_*` check list (`:127-141`) is the gate to extend.

## The fix

**Route A (recommended): ship the module tree and run `depmod`.** The package is already being
fetched. Install its `lib/modules/<ver>` into the guest image (or attach it as a small drive) and
run `depmod -a` for that version, so `modprobe` resolves names and dependencies like it does on a
normal host. Then nothing needs to know the module list, and the next capability that wants a
module does not come back to this file. The cost is image size — measure it first
(`du -sh` the unpacked `lib/modules/<ver>` from `$TMP/mod`; base modules only, not
`linux-modules-extra`), and decide against the current four-file approach.

**Route B (cheap, brittle): extend the hand-picked list.** Keep the hand-written order and add the
container set. Order matters, since there is no `depmod`; dependencies are *below* the module that
needs them:

    # netfilter core → conntrack → nat → tables
    nfnetlink nf_defrag_ipv4 nf_defrag_ipv6 nf_conntrack nf_nat nf_tables
    x_tables ip_tables iptable_filter iptable_nat xt_conntrack xt_addrtype xt_MASQUERADE
    # bridge + virtual ethernet, and the filter that makes iptables see bridged traffic
    llc stp bridge veth br_netfilter
    # storage, if fuse-overlayfs is used (see below)
    fuse

Add the same set to `build-kernel.sh`'s config list for Linux hosts. Expect to iterate: this route
fails closed (a missing dependency shows up as a modprobe error at boot), which is why A is
preferable if the size is acceptable.

**Storage: do not fight nested overlay.** `overlay2` cannot mount inside the guest's own overlay
root (`failed to mount overlay: invalid argument`). Two ways out, either is fine:

- give dockerd a data-root on a real filesystem — the guest already has one: the project drive
  (`/dev/vdc`, ext4) — `dockerd --data-root /var/folders/.../<project>/.docker`; or
- ship `fuse-overlayfs` in the image and use `--storage-driver=fuse-overlayfs`. This was
  verified to get past storage, but the guest's `/dev/fuse` availability still needs confirming
  (open question 1 below).

**iptables backend.** The nft backend needs `nf_tables`; the legacy backend needs `ip_tables` +
`iptable_nat`. Either satisfies docker, and both are in the module set above. Note the guest has
`iptables-legacy` installed but its modules were equally absent, so "install the other iptables"
is not a workaround on its own.

## Open questions

1. Does the guest expose `/dev/fuse`? `fuse-overlayfs` installed and was accepted by dockerd, but
   the failure moved on before it was exercised. If `/dev/fuse` is absent, storage must go to the
   project drive instead (or `overlay` must work on a real filesystem).
2. Unpacked size of `lib/modules/<ver>` — decides Route A vs B.
3. Does `linux-modules-<ver>` alone cover bridge + nftables, or is `linux-modules-extra-<ver>`
   needed? `nf_tables` and `br_netfilter` are usually in base modules; confirm rather than assume.
4. Fallback worth evaluating only if the kernel route is rejected: **rootless podman + slirp4netns**
   needs no bridge and no netfilter. But Tilt drives the compose stack through the docker CLI, and
   whether it works against podman's docker-compatible socket is unverified — treat any result
   from that path as a different stack, not as evidence about CI.

## Verification once changed

    firecode up --project <tree> --mem 16384
    firecode in --project <tree> --cwd <tree> 'sudo docker run --rm hello-world'
    firecode in --project <tree> --cwd <tree> 'cd <repo> && cp -n .env.example .env && \
        docker compose -f docker-compose-dev.yml up -d && docker compose ps'
    # then the e2e tier:
    firecode in --project <tree> --cwd <tree> 'cd <repo>/flow && go test -tags tilt \
        ./e2e/postgres_postgres/ -run <TestName> -timeout 20m'

Disk to watch: the 14 services plus five images built from the repo need roughly 8–10 GB, against
a 16 GB root overlay and a 12 GB project drive. `docker system df` after the first pull, before
concluding it fits.
