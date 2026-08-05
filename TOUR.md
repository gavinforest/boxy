# A tour of boxy

Every block below is **real output** captured on an arm64 Mac against a live
Docker daemon, not illustrative. Paths have been shortened from the throwaway
test directory to `~/.local/share/boxy` for readability — that is where they
land in normal use.

Companion docs: [README.md](README.md) for reference, this file for the
walkthrough.

---

## 0. The one-paragraph version

`boxy` gives you disposable Debian containers that behave like small remote
machines: you SSH into them with a known key, they have a scientific Python
stack preinstalled, they mount a directory of yours at `/work`, they expose
services either through an SSH tunnel that keeps the port number identical or
through an explicit docker-style `-p`, and their internet access can be
switched off or narrowed to an allowlist. Nothing secret is baked into the
image — keys, password hashes, repo URLs and proxy settings all arrive at
`docker run` time.

---

## 1. The surface

Commands are grouped by whether they are boxy's own or a thin wrapper over
docker — you asked, reasonably, which is which:

```
$ boxy --help
boxy 1.0.0 — disposable SSH-reachable dev boxes

usage: boxy <command> [options]

CORE — the reason boxy exists
  create [options]           create and start a box   (boxy create --help)
  ssh [NAME] [-- CMD]        interactive session, or one command
  forward [NAME] [PORTS]     tunnel box ports to the SAME localhost ports
  rm NAME...                 remove a box (never touches your files)
  ls                         list boxes
  info [NAME]                one box in detail, including its port map
  password [NAME]            print the stored sudo password
  ssh-config [--install]     emit/install an ssh_config covering every box
  build [--full]             build the images     (boxy build --help)
  doctor                     check the local setup
  config [--init]            show or scaffold configuration

DOCKER PASSTHROUGH — thin wrappers that resolve the name and add boxy's
defaults, then hand off. Equivalent plain-docker command in brackets.
  exec [NAME] [CMD]          [docker exec]    a way in that does not use ssh
  logs [NAME] [-f]           [docker logs]    the box's entrypoint narration
  start|stop|restart [NAME]  [docker start…]  lifecycle
  top [--watch]              [docker stats]   live CPU/memory per box
  monitor up|down|status     [docker compose] optional prometheus + grafana

The name may be omitted whenever exactly one box exists.
```

Sidecars do not count toward that: a `--net limited` box brings a proxy
container carrying the same `boxy.managed` label, and an earlier version
counted it — so `boxy ssh` on a single limited box refused with
"there are 2". Name-omission now counts boxes (`boxy.role=box`) only.

The passthroughs earn their place by resolving the box name and supplying
defaults you would otherwise have to remember — `boxy exec` sets the box user,
`$HOME` and `/work`; `boxy start` re-applies egress isolation and re-pins the
host key. If you would rather not use them, the container name *is* the box
name, so `docker logs boxy-1` works exactly as you would expect.

`boxy doctor` says whether the machine is ready. It is deliberately relaxed
about things created lazily:

```
$ boxy doctor
boxy 1.0.0

  docker cli               29.6.2
  docker daemon            reachable
  image boxy:latest        present
  image boxy-proxy:latest  present
  boxy keypair             not yet generated (created on first boxy create)
  git key                  ~/.ssh/id_ed25519
  EFF wordlist             not cached (fetched on first create)
  config                   ~/.config/boxy/config
  state                    ~/.local/share/boxy

looks healthy
```

---

## 2. Creating a box

```
$ boxy create -d ~/code/demo

no boxy keypair at ~/.local/share/boxy/boxy_ed25519 — generating one
created ~/.local/share/boxy/boxy_ed25519
cached EFF long wordlist (7776 words) at ~/.local/share/boxy/eff_large_wordlist.txt

created instance 1 (boxy-1), ssh at port 2200
  ssh     ssh -F ~/.local/share/boxy/ssh_config boxy-1        (or: boxy ssh boxy-1)
  direct  ssh -p 2200 -i ~/.local/share/boxy/boxy_ed25519 boxyboy@127.0.0.1
  workdir ~/code/demo -> /work
  net     full
  sudo pw praying-tameness-hurled-fossil   (boxy password boxy-1)
  ports   none published — boxy forward boxy-1 tunnels 2718 8888 8000 8080 3000 5000 6006
```

~4 seconds from cold, including generating the keypair and downloading the
wordlist. Subsequent creates take ~3s.

### What landed on the host

```
~/.local/share/boxy
~/.local/share/boxy/boxy_ed25519
~/.local/share/boxy/boxy_ed25519.pub
~/.local/share/boxy/eff_large_wordlist.txt
~/.local/share/boxy/instances/boxy-1/hostkeys
~/.local/share/boxy/instances/boxy-1/known_hosts
~/.local/share/boxy/instances/boxy-1/password
~/.local/share/boxy/ssh_config
```

That `instances/boxy-1/` directory is bookkeeping with the same lifetime as
the container — `boxy rm` deletes it. Your actual files are elsewhere: either
the directory you passed to `-d`, or a fresh scratch dir under
`$TMPDIR/boxy/` when you didn't.

Note where the keypair is: **boxy's own state directory, not `~/.ssh`**. boxy
creates and manages this key, so it belongs with boxy's other state, where
`rm -rf ~/.local/share/boxy` is a complete uninstall. Nothing boxy does writes
to `~/.ssh` unless you explicitly run `boxy ssh-config --install`. Set
`BOXY_SSH_KEY` if you would rather supply your own key.

### Where the state actually lives

There is no database. Docker labels are the single source of truth:

```
$ docker inspect boxy-1 --format '{{json .Config.Labels}}'
  boxy.caps          minimal
  boxy.created       2026-08-04T23:32:50Z
  boxy.index         1
  boxy.managed       1
  boxy.net           full
  boxy.published     
  boxy.role          box
  boxy.ssh_port      2200
  boxy.user          boxyboy
  boxy.workdir       /Users/gavin/code/demo
```

boxy reads these with `docker inspect --format` (Go templates) — there is **no
`jq` dependency**. `boxy ls` is a `docker ps` filter over the same labels.
Delete a container by hand and boxy's view is instantly correct rather than
stale; there is nothing to reconcile.

---

## 3. The password, and where it isn't

Four words from the EFF long (7776-word) list, ~51.7 bits:

```
$ boxy password boxy-1
disarm-massager-uprising-shed

$ ls -l ~/.local/share/boxy/instances/boxy-1/password
-rw-------  ... password
```

What the container actually received:

```
BOXY_AUTHORIZED_KEYS=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEDW9yM2gHDe3cFzsiyaguS00s94foRUHYlixT…
BOXY_PASSWORD_HASH=$6$qvCefvsdcbTpEYGe$GdZm1Rcy47vYTxE3nsOrYtumw/Lrr1aj.Q4ivuSXoN8F5.QtbqADsINa…
```

The plaintext is hashed on the *host* with `openssl passwd -6` and only the
sha512-crypt hash crosses the boundary. The entrypoint feeds it to
`chpasswd -e` and then unsets it, so it appears in no image layer, no
`docker inspect`, and no `/proc/<pid>/environ`.

Word selection uses rejection sampling against `/dev/urandom` rather than a
plain modulo — `rand % 7776` over 16 bits quietly favours the first 1216 words,
which is not a property you want in a password generator.

### The password gates sudo, and only sudo

```
without it : sudo: a password is required
with it    : uid=0(root) gid=0(root) groups=0(root)
```

`sshd` never accepts it: `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitRootLogin no`, plus an `AllowUsers`
line pinned to the box user. A box exposed on a public interface cannot be
brute-forced into.

---

## 4. Host keys are pinned, not trusted-on-first-use

The `known_hosts` entry boxy wrote, and the key read straight off the
bind-mounted state directory:

```
known_hosts:  [127.0.0.1]:2200 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXng2/CVus/zpHJAorQCcZ2T3KHwNaXakfEKwZpVVA4
hostkeys/:                    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXng2/CVus/zpHJAorQCcZ2T3KHwNaXakfEKwZpVVA4
```

They match because `<state>/hostkeys` is bind-mounted into the container.
boxy reads the box's public host key off the host filesystem and writes a real
`known_hosts` entry *before you ever connect*. Result: full host-key
verification from the first connection — no TOFU prompt, no
`StrictHostKeyChecking=no`, and the fingerprint survives `boxy restart`
(verified).

---

## 5. Inside a box

`boxy ssh <name>` with no trailing command gives you a **live interactive
session** — a real login shell on a real PTY, not a wrapper:

```
$ boxy ssh boxy-1
Linux boxy-1 6.12.76-linuxkit #1 SMP aarch64

  boxy: boxy-1
  workdir: /work   user: boxyboy
  python: Python 3.12.13
  Bind servers to 0.0.0.0 (e.g. marimo edit --host 0.0.0.0) to reach them
  from the host on published ports.

(base) boxyboy@boxy-1:/work$ whoami
boxyboy
(base) boxyboy@boxy-1:/work$ tty
/dev/pts/0
(base) boxyboy@boxy-1:/work$ echo $-
himBHs
(base) boxyboy@boxy-1:/work$ ls
notes.md  src
(base) boxyboy@boxy-1:/work$ exit
logout
Connection to 127.0.0.1 closed.
```

`/dev/pts/0` confirms a genuine pseudo-terminal and the `i` in `himBHs`
confirms an interactive shell, so job control, `Ctrl-C`, `Ctrl-Z`, curses
programs and window resizing all behave normally. `(base)` is the conda
environment; the prompt shows you land in `/work`.

Internally `cmd_ssh` ends in `exec ssh …`, which **replaces** the boxy process
rather than spawning a child. There is no shell sitting between you and the
session — signals, exit codes and SSH's own `~.` escape sequences reach `ssh`
directly, exactly as if you had typed the full command yourself.

Add a command and you get a one-shot, non-interactive run instead (no PTY,
which is the right default for scripts and agents):

```
$ boxy ssh boxy-1 -- tty
not a tty
$ boxy ssh boxy-1 -- pwd
/work
$ boxy ssh boxy-1 -- 'python -c "print(2**16)"'
65536
```

Both forms land in `/work`. Note that `/work` is a **directory** — the mount
point for whatever you passed to `-d` (or the cloned repo):

```
(base) boxyboy@boxy-1:/work$ stat -c %F /work
directory
(base) boxyboy@boxy-1:/work$ ls -la /work
drwxr-xr-x 4 boxyboy boxyboy  128 .
-rw-r--r-- 1 boxyboy boxyboy   38 notes.md
drwxr-xr-x 3 boxyboy boxyboy   96 src
```

Its contents are your host directory's contents, live in both directions.

The stack:

```
  python   3.12.13
  jax      0.11.0 backend: cpu | devices: [CpuDevice(id=0)]
  numpy    2.5.1  scipy 1.18.0  pandas 3.0.5
  polars   1.43.2  sklearn 1.9.0

  marimo      0.23.16
  jupyter-lab 4.6.2
  node        v26.5.1
  npm         11.17.0
  uv          0.12.1
  conda       26.7.0
  mamba       2.5.0
  git         2.39.5
  rg          13.0.0
  claude      2.1.221 (Claude Code)
```

Real work, over SSH, non-interactively:

```
$ ssh boxy-1 'python -c "..."'
  jit-compiled 512x512: 717.1864013671875
  grad: 0.5403022766113281
```

### Nothing needs sudo

```
  boxyboy:boxyboy /home/boxyboy
  boxyboy:boxyboy /opt/conda
  boxyboy:boxyboy /work
```

```
$ boxy ssh boxy-1 'pip install seaborn'
  installed seaborn 0.13.2 into /opt/conda as boxyboy
```

The conda prefix is owned by the box user because everything is installed *as*
that user at build time. The obvious alternative — `RUN chown -R` at the end —
costs 3.44 GB, because Docker layers are copy-on-write per file and a metadata
change rewrites every one of ~40k files into the new layer. Avoiding it took
the image from **7.41 GB to 3.97 GB**.

### The volume is live in both directions

```
  host -> box : # a file that was already on the host
  box  -> host: the answer is 42
  host dir    : notes.md results.txt
```

---

## 6. Ports

Only SSH is published automatically: instance *N* gets `2200 + N - 1`.

```
$ boxy create -n api
created instance 2 (api), ssh at port 2201
  ports   none published — boxy forward api tunnels 2718 8888 8000 8080 ...
```

`api` and `scratch` here are just names passed to `-n`; there are no built-in
box types. Without `-n` you get `boxy-1`, `boxy-2`, …

```
$ boxy ls
NAME         STATUS    SSH    NET      WORKDIR
api          running   2201   full     ~/.local/share/boxy/instances/api/work
scratch      running   2202   full     ~/.local/share/boxy/instances/scratch/work
boxy-1       running   2200   full     ~/code/demo
```

### Reaching a service: two explicit mechanisms

**`boxy forward`** keeps the number identical on both sides. This is the
default path, and there is nothing to decode:

```
$ boxy forward boxy-1 --bg 8000
tunnelling 8000 in the background (boxy forward boxy-1 --stop to end)

$ curl localhost:8000
results.txt

$ boxy forward boxy-1 --stop
stopped tunnel for boxy-1
```

**`-p`** publishes, with exactly docker's semantics — a bare port means the
same number, `HOST:CONTAINER` states it explicitly:

```
$ boxy create -n pub -p 28000:8000 -p 29999
$ boxy info pub
published   localhost:28000 -> 8000   localhost:29999 -> 29999
forwardable 2718 8888 8000 8080 3000 5000 6006   (boxy forward pub)
```

A taken host port is an error before anything is created, not a silent remap:

```
$ boxy create -n dup -p 28000:8000
error: --publish 28000:8000: host port 28000 is already in use
```

> An earlier version of boxy auto-published every port in `BOXY_PORTS` into a
> per-instance 100-port block (`20000`, `20100`, …). It was removed: decoding
> that `20002` meant `8000` required knowing the *ordering* of a config list,
> which is a worse mapping than no mapping.

> Servers must bind `0.0.0.0` to be reachable through a **published** port
> (`marimo edit --host 0.0.0.0`). Binding `127.0.0.1` is fine over
> `boxy forward`, since the tunnel terminates inside the container's own
> loopback.

---

## 7. Limiting internet access

```
boxy create --net full      # default, unrestricted
boxy create --net none      # no route off the host
boxy create --net limited   # allowlisting proxy only
```

### How, and why not the obvious way

The obvious implementation is `docker network create --internal`. I built it
that way first and it fails: an internal network blocks egress *and* the
inbound traffic published ports depend on, so `--net none` boxes became
unreachable over SSH — which defeats the entire premise. The readiness check
caught it rather than reporting a healthy box.

What works instead is an ordinary bridge with the **default route deleted**.
On-link traffic still flows — replies to published ports reach the host, and a
proxy sidecar on the same subnet stays reachable — while anything needing a
gateway goes nowhere.

The route is removed from the *host* via `docker exec --privileged`, which
grants privileges to that single exec'd process. The container itself never
holds `CAP_NET_ADMIN`:

```
  ssh works on an isolated box     PASS
  no default route                 PASS
  https blocked                    PASS
  raw IP blocked                   PASS
  box root CANNOT restore the route PASS   ← sudo ip route add default
                                            → RTNETLINK answers: Operation not permitted
  no default route after restart   PASS
  still blocked after restart      PASS
  external name resolution is dead PASS   <- DNS covert channel
  TXT lookups cannot smuggle data  PASS
  host-netns service unreachable   PASS   <- on-link gateway
  box cannot alter its own firewall PASS
```

### Two holes route removal does not close

Both were found by probing rather than reasoning, and both are now shut:

**DNS was a working covert channel.** Docker's embedded resolver forwards
queries through the daemon, which sits outside the container's network
namespace — so a `--net none` box with no route anywhere still resolved names,
and a `dig TXT google.com` returned a real record. Data out in query labels,
data back in TXT answers. Isolated boxes now get `--dns 127.0.0.1`; container
names still resolve, which is all a box needs to reach its proxy.

**The gateway stayed reachable.** Route removal only stops traffic that needs
a gateway; the gateway address is on-link. A service in the host's network
namespace answered with 200 from inside a "no network" box — on a VPS that is
sshd, the Docker API, Grafana. An `OUTPUT` firewall now closes it:

```
$ docker exec --privileged ltd iptables -S OUTPUT
-P OUTPUT DROP
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d 172.19.0.2/32 -j ACCEPT      # the proxy, --net limited only
```

The rules are stateful on purpose: inbound SSH arrives by DNAT *from* the
gateway and replies go back to it, so a blanket drop would cut the connection
you are sitting on. And they go in by privileged exec, so reading them from
inside the box fails:

```
$ sudo iptables -S OUTPUT
iptables v1.8.9 (nf_tables): Could not fetch rule set generation id:
Permission denied (you must be root)
```

Isolation is reapplied on every `start`/`restart`, since a restart rebuilds
the network namespace and keeps neither the route change nor the firewall.

### `--net limited`

A per-box tinyproxy sidecar sits on both the box's subnet and a normal bridge,
making it the single path out. It refuses any domain not in
`~/.config/boxy/allowlist.txt`.

```
  allowlisted pypi -> 200                   PASS
  non-allowlisted http -> 403               PASS
  non-allowlisted https -> refused          PASS
  direct (non-proxied) egress still blocked PASS
  --allow adds a domain                     PASS
```

```
$ docker logs boxy-proxy-ltd
NOTICE  Proxying refused on filtered domain "example.com"
```

A blocked **HTTPS** request shows up as `curl` exit 7 / status `000`, not a
403 — HTTPS goes through as `CONNECT` and tinyproxy refuses by dropping the
tunnel, so there is no HTTP response to carry a status. Plain HTTP returns a
real 403.

The shipped allowlist covers PyPI, conda-forge, GitHub, npm, Debian, Hugging
Face and the Anthropic API.

---

## 8. Using a box as a remote

`boxy` regenerates a standalone `ssh_config` on every create/remove:

```
# Generated by boxy 1.0.0 — regenerated on every create/rm.

Host api
    HostName 127.0.0.1
    Port 2201
    User boxyboy
    IdentityFile ~/.local/share/boxy/boxy_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile ~/.local/share/boxy/instances/api/known_hosts
    StrictHostKeyChecking yes
    ForwardAgent no
    ServerAliveInterval 30
```

```
boxy ssh-config --install    # Include it from ~/.ssh/config
```

After that, `ssh api` works from anything that speaks SSH — verified with
`ssh`, `scp` and `rsync`. That is what lets Claude Code (or VS Code
Remote-SSH) treat a box as an ordinary remote host.

`boxy exec` is the escape hatch that does not involve SSH at all:

```
$ boxy exec boxy-1 'echo "exec as $(whoami), HOME=$HOME, cwd=$(pwd)"'
exec as boxyboy, HOME=/home/boxyboy, cwd=/work
```

---

## 9. Monitoring

Two tiers, and the light one is the default answer.

**`boxy top`** — no extra services, straight from the daemon:

```
$ boxy top
NAME      CPU %     MEM USAGE / LIMIT    MEM %     NET I/O
scratch   0.01%     2.219MiB / 7.75GiB   0.03%     6.32kB / 5.44kB
api       0.03%     12.93MiB / 7.75GiB   0.16%     14.1kB / 12.9kB
boxy-1    0.04%     14.94MiB / 7.75GiB   0.19%     35.3kB / 34.8kB
```

**`boxy monitor up`** — opt-in, for the one question `top` cannot answer:
*what happened while I wasn't looking?*

```
$ boxy monitor up
grafana at http://localhost:3001 (admin / admin on first login)
prometheus at http://localhost:9090
```

### Why four containers rather than one

Each does one job, and they are separable:

| Container | Job | Droppable? |
| --- | --- | --- |
| cAdvisor | reads the cgroup tree → per-container CPU/mem/net | no — this is the actual data |
| node-exporter | host CPU/mem/disk headroom | yes, if you only care per-box |
| Prometheus | stores and queries the history | no — history *is* the feature |
| Grafana | draws it | yes — Prometheus has its own basic UI at :9090 |

Collapsing them is not really an option: cAdvisor and node-exporter are
upstream single-purpose exporters, and Prometheus's whole design is that
collection and storage are separate processes. A genuinely smaller setup means
choosing a different tool, not merging these.

`--store_container_labels=false` keeps cAdvisor from emitting every Docker
label as a Prometheus label, which would be a real cardinality problem. Per-box
series are selected on `container_label_boxy_role="box"` rather than a name
regex, so custom-named boxes are included and the monitoring stack's own
containers — and the proxy sidecars — are excluded.

**Cost:** ~830 MB of images (grafana 467, prometheus 269, cadvisor 70,
node-exporter 23) plus TSDB disk. Off unless you type `boxy monitor up`. On a
laptop `boxy top` is almost certainly enough.

---

## 10. Lifecycle and the working directory

```bash
boxy stop|start|restart <name>
boxy logs <name> -f          # the entrypoint narrates every step here
boxy rm <name>
```

`boxy logs` is `docker logs` of the box, which is the entrypoint's setup
narration — host-key generation, authorized-keys install, password set,
isolation confirmed, clone succeeded or failed. It is the first place to look
when a box misbehaves, and it is why a failed clone leaves the box *running*
rather than dead: you can still get in and read why.

### Where your files live

```bash
boxy create -d ~/code/thing    # mount a directory you own
boxy create                    # fresh scratch dir in $TMPDIR/boxy/
```

With `-d`, that directory is mounted at `/work` as-is — never created, never
moved, never deleted. Without it, boxy makes a fresh directory under
`$TMPDIR/boxy/<name>.XXXXXX` (`mktemp`, so a recreated box never inherits a
previous one's leftovers) and then stops caring about it. Temp directories are
the OS's job to reap.

### `boxy rm`

One behaviour, no flags, no prompt:

```
$ boxy rm boxy-1
removed boxy-1
  workdir left for the OS to reap: /var/folders/…/T/boxy/boxy-1.VUiiNA

$ boxy rm mine
removed mine
  your directory is untouched: /Users/gavin/code/thing
```

It deletes the container, the proxy sidecar and per-box network if there were
any, and boxy's per-instance bookkeeping — host key, `known_hosts`, password
file. None of that means anything once the box is gone.

There is no `--purge` and no confirmation, because there is nothing to
confirm: `rm` cannot destroy anything of yours. Your files are either in a
directory you named, or still sitting in the temp area.

> An earlier version kept that bookkeeping after `rm` so that recreating under
> the same name would adopt the old host key and password. It was removed —
> preserving credentials nobody asked to keep is not an undo, it is a second
> lifecycle to reason about.

---

## 11. Container privileges

Boxes run with a reduced capability set by default — 10 of Docker's 14:

```
$ boxy info boxy-1 | grep caps
caps        minimal

$ docker exec boxy-1 sh -c 'capsh --decode=$(grep CapBnd /proc/1/status|cut -f2)'
cap_audit_write cap_chown cap_dac_override cap_fowner cap_kill
cap_net_bind_service cap_net_raw cap_setgid cap_setuid cap_sys_chroot
```

Dropped: `MKNOD`, `SETPCAP`, `SETFCAP`, `FSETID`. Nothing in a dev box has a
plausible use for creating device nodes or editing capability sets.

The set is tuned for **usability over provable minimality**, which is a
deliberate choice given what these boxes are for. Each retained capability is
retained because losing it produces a confusing failure rather than an honest
one. The sharpest example, found by testing rather than reasoning:

```
$ ping -c1 127.0.0.1
exec /usr/bin/ping: operation not permitted
```

`/usr/bin/ping` carries the file capability `cap_net_raw=ep`. The `e`
(effective) bit means that when `NET_RAW` is outside the bounding set, `exec`
of the binary fails outright — not a degraded ping, a binary that will not
start, reporting an error that points nowhere near capabilities. `KILL` is the
same story (`sudo pkill` silently fails without it), as are
`NET_BIND_SERVICE` and `AUDIT_WRITE`.

Verified still working under the reduced set: ssh login, sudo to uid 0, ping,
binding port 80 as an unprivileged user, `pip install`, and `git clone`.

`boxy create --caps default` restores Docker's full 14 — the fastest way to
rule capabilities in or out when something misbehaves.

### gVisor

```bash
boxy create --runtime runsc
```

A user-space kernel: gVisor reimplements the Linux syscall interface in a Go
process, so a kernel exploit from inside the box hits that reimplementation
instead of the host kernel.

It earns its keep on a **Linux VPS**, where the container kernel *is* the host
kernel. On Docker Desktop it is close to pointless, and you can see why:

```
$ docker run --rm boxy:latest uname -r
6.12.76-linuxkit          # the VM's kernel — macOS is Darwin 25.5.0
```

Containers there already run inside a VM, so an escape lands in a disposable
Linux VM rather than on macOS. gVisor ships with neither Docker nor Docker
Desktop's VM, so the flag is inert until `runsc` is installed on the host.

---

## 12. Test status

```bash
./test/run.sh              # every suite
./test/run.sh core         # just one
```

```
core:     45 passed, 0 failed
network:  27 passed, 0 failed
workflow: 28 passed, 0 failed

all suites passed
```

100 assertions, all green. The suites run against a scratch `BOXY_STATE_DIR`
under `$TMPDIR` with their own keypair, so they cannot touch a real install or
your `~/.ssh` — though they *do* remove every boxy-managed container on the
host, since a shared Docker daemon is the one resource they cannot sandbox.

| Suite | Covers |
| --- | --- |
| `core` | creation, the box interior, the volume, sudo, sshd hardening, host-key pinning, capability policy |
| `network` | `--net none` / `--net limited`, DNS and on-link hardening, restart persistence, allowlist, teardown |
| `workflow` | ports and `-p`, forwarding, cloning, `ssh_config`, `exec`, the rm/workdir contract |

---

## 13. Known gaps

- **The VPS/tailscale path is wired but untested against real hardware.**
  `--tailscale` runs `tailscaled` in userspace-networking mode (no
  `/dev/net/tun`, no `NET_ADMIN`); remote targeting is
  `docker context create vps --docker "host=ssh://…"`, since boxy only ever
  talks to `docker`. Both need verifying on an actual VPS.
- **JAX is CPU-only.** GPU needs a CUDA build target and `jax[cuda12]`
  (amd64 only).
- **`--net limited`/`none` are guardrails, not a sandbox.** An isolated box
  cannot reach the internet, the host, or another box. It *can* do whatever it
  likes with what you handed it: the mounted directory is read-write, a
  mounted git key is readable, and the allowlist constrains where you can talk
  rather than what you can say — a POST from a limited box reaches
  `api.github.com` and gets a real answer.
- **`BOXY_GIT_KEY` is readable by the box user.** Unavoidable if you want to
  push from inside; use `--no-git-key` or a dedicated deploy key otherwise.
