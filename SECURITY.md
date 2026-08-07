# Security model

What boxy actually enforces, how the two containers are built, where the logs
go, and which of it holds up when something is compromised.

This describes the design. The claims marked *verified* are asserted by
`test/network.sh`, so they fail the suite if they stop being true.

---

## What is trusted

```
   trusted        the host, the docker daemon, and boxy itself
   semi-trusted   the sidecar — small, but dual-homed and internet-facing
   untrusted      the box — it runs whatever you put in it
```

The box is the thing being contained. It has `sudo` inside the container, so
the box user is expected to become container root; nothing in this document
depends on it not doing so.

The sidecar sits between the box and the network. It is the only container
with a foot on both sides, which makes it the interesting target and the
reason it is kept as small as it is.

The host is outside all of it. A compromised host ends every guarantee here at
once, and no arrangement of containers changes that.

---

## The three network modes

`--net` decides whether a box can reach the internet, and it is enforced by
Docker rather than by anything inside the container.

```
  --net full        (the default)
     host ──publish──▶ box:22                      no sidecar exists
     box  ──▶ boxy-net (ordinary bridge) ──▶ internet

  --net limited
     host ──publish──▶ sidecar:2200 ──socat──▶ box:22
     box  ──HTTPS_PROXY──▶ sidecar:8888 ──┐
                                          └─allowlist─▶ internet
     box  ──▶ boxy-iso-<name>   --internal: no route, no NAT, no DNS

  --net none
     host ──publish──▶ sidecar:2200 ──socat──▶ box:22
     box  ──▶ boxy-iso-<name>   nothing to reach; no proxy runs
```

An isolated box's network is created with `--internal`, so Docker installs no
route and no NAT for it. There is nothing inside the box to switch off, and
`CAP_NET_ADMIN` is never granted, so `sudo ip link add` fails. *Verified.*

A consequence worth naming: **DNS is dead in an isolated box** without boxy
doing anything, which closes what would otherwise be a bidirectional covert
channel — data out in query labels, answers back in TXT records. Container
names still resolve, which is how the sidecar finds the box.

Each isolated box gets its own subnet, so boxes cannot reach each other.

---

## What the box container gets

```
   host                                    box
   ────                                    ───
   <state>/boxy_ed25519.pub ──env──────▶   ~boxyboy/.ssh/authorized_keys
   password (plaintext, 0600) ──hash───▶   chpasswd -e        (sudo only)
   <workdir> ──mount───────────────────▶   /work
   <repo>/.git   (worktree boxes) ─────▶   <repo>/.git        (same path)
   <state>/hostkeys ──mount────────────▶   /etc/ssh/hostkeys
   127.0.0.1:2200 ──publish────────────▶   :22                (full boxes only)
```

- **SSH is key-only.** `PasswordAuthentication no`, `PermitRootLogin no`. The
  password exists for `sudo` and is never accepted by sshd.
- **Published ports bind to loopback** by default (`BOXY_BIND_ADDR=127.0.0.1`).
- **No docker socket, ever** — not in the box, not in the sidecar. There is no
  path from inside a container to the daemon.
- **No git credentials enter a box.** A worktree box shares your repository's
  object store, so it can commit; it holds no key and can push nowhere.
- **Capabilities**: `--caps minimal` is the default — `--cap-drop=ALL`, then
  back only `CHOWN DAC_OVERRIDE FOWNER KILL SETGID SETUID SYS_CHROOT
  NET_BIND_SERVICE NET_RAW AUDIT_WRITE`.

An isolated box publishes **nothing** itself. Docker silently discards `-p` on
an internal network, so those bindings live on the sidecar instead — which is
why a port that never answers is a sidecar question, not a box question.

---

## Inside the sidecar

One process per job, each with the least it can do them with.

| process | uid | reads | can be attacked by |
| --- | --- | --- | --- |
| entrypoint (PID 1) | 0 | its own config | nothing; boxy's own script |
| `socat :2200 ▶ box:22` | 65534 | inbound TCP | anyone reaching a published port |
| `tee -a ingress.log` | 0 | socat's stderr | nothing (socat's own output) |
| `grep` (E/F filter) | 0 | socat's stderr | nothing (socat's own output) |
| `tinyproxy :8888` | 100 | every request the box makes | the box |

```
   --cap-drop=ALL, then:
      --net limited   + KILL SETGID SETPCAP SETUID
      --net none      + nothing
   --sysctl net.ipv4.ip_forward=0
   /etc/boxy-proxy    read-only mount     the egress allowlist
   /var/log/boxy      700 root            ingress.log is 600 root
```

The four capabilities are not decoration. Three are tinyproxy's own privilege
drop; `KILL` is the supervisor's, so it can stop tinyproxy for an allowlist
reload once tinyproxy is no longer running as root. *Verified: exactly those
four, and none at all on an ingress-only sidecar.*

**socat runs unprivileged.** It never needed root: Docker sets
`net.ipv4.ip_unprivileged_port_start=0`, so any uid binds any port, and the
outbound connect needs nothing either. It used to be root purely by
inheritance from a supervisor that must be root for tinyproxy's sake — and
root in a *proxying* sidecar is not toothless, since anything landing there
could kill tinyproxy and put an allowlist-free proxy on 8888. *Verified: uid
65534.*

An ingress-only sidecar keeps socat as root, deliberately. With no
`CAP_SETUID`, `CAP_KILL` or `CAP_DAC_OVERRIDE`, that root cannot become
another user, signal one, or step past a file mode — and granting capabilities
purely so they could be dropped would widen the container in order to harden
it.

**The allowlist is mounted read-only**, so a compromised sidecar cannot make a
widening of its own policy stick. It is a directory mount rather than a file
mount, because a single-file bind pins one inode and any editor that saves by
rename would leave the container reading the old contents forever.

---

## Logging

Two containers, four writers, one store — and the store is the part that
matters, because it is not reachable from either container.

```
   written by             stored in                      read with
   ──────────             ─────────                      ─────────
   tinyproxy   stdout ┐
   entrypoint  stderr ┼──▶ docker's json-file log ────▶  boxy logs [-s]
   socat E/F   stderr ┘    (host side, undeletable)

   socat -dd   all    ───▶ /var/log/boxy/ingress.log ─▶  boxy logs -v
                           (in the sidecar, 600 root)    (via docker cp)

   both read paths pass through strip_ctl; --raw skips it
```

**Logs cannot be deleted by a compromised container.** Container output is
consumed by the daemon and written on the host; no socket is mounted, so there
is no path from inside to the store. This is a property of the daemon
boundary, not of anything boxy does.

**A box cannot forge a log line.** tinyproxy echoes the requested domain into
its denial line, so the box chooses bytes that land in the log — but a bare CR
truncates the host and `%0d%0a` is never decoded, so no new line can be
manufactured. *Verified.*

**A box could otherwise make the log lie on screen.** Those same bytes may
include `ESC`, which lets it drive the cursor of whoever is reading and paint
over lines already displayed. `boxy logs` strips C0 control characters for
this reason — unconditionally, not gated on `isatty`, because `boxy logs |
grep` renders at the end of a pipeline and boxy cannot see that far. `ESC`
alone is removed, so an injected `[2A` survives as visible text rather than
disappearing. *Verified.*

**The ingress audit trail** records every connection through the relay. It
lives in a file rather than the container log because socat at `-dd` spends
about a dozen lines on one connection, which would bury the faults. Only
error-level lines are echoed back, so the container log keeps meaning
"something is wrong" while the file holds "what happened". Warnings are
excluded on purpose — `connection reset by peer` fires on every ordinary
close, so passing them would let anyone reaching a published port flood the
log. *Verified: accepts stay out, errors get through, warnings do not.*

The trail is read with `docker cp`, which works on a **stopped** container —
a sidecar that has fallen over is when it is worth having. It is root-owned
`600` inside a `700` directory, reapplied at every start, so tinyproxy — the
one process an attacker could land in — cannot read the inbound peer addresses
of connections it has nothing to do with. `tee` stays root for the same
reason in reverse: the relay must not be able to rewrite the trail that
recorded it. *Verified.*

Both the container log and the audit trail are destroyed by `boxy rm`, along
with the containers. Neither survives the box.

---

## How boxy interacts with all this

boxy is a shell script on the host that drives the docker CLI. It holds no
daemon of its own and installs nothing inside a box.

- **State lives in container labels**, not in a database — `boxy.net`,
  `boxy.caps`, `boxy.ssh_port` and the rest are read back with `docker
  inspect`. `boxy info` reports the labels *and* the observed reality, so the
  two disagreeing is visible rather than silent.
- **Per-box secrets live on the host**, under the state directory: the sudo
  password (plaintext, `0600`) and the SSH host keys. The sidecar's allowlist
  gets its own subdirectory precisely so that mounting it exposes neither.
- **`boxy allow` changes egress without a restart** by rewriting the
  host-side allowlist and signalling the sidecar, which rebuilds its filter
  and restarts only tinyproxy. The socat listeners — and with them every live
  SSH session — stay up. The reload is confirmed by reading a generation
  counter before and after, so a change that did not take is reported as a
  failure rather than assumed to have worked.
- **Removal is bounded**: `boxy rm` deletes the containers, the per-box
  network and boxy's own bookkeeping. A `-d` directory you named is never
  touched.

---

## What does not hold

Stated plainly, because a security document that only lists wins is not much
use.

- **The kernel is shared.** A kernel privilege-escalation bug escapes
  everything above at once — namespaces, cgroups, seccomp and capabilities are
  all enforced by the thing that just got compromised. On Docker Desktop this
  lands in the VM's kernel, so an escape reaches a disposable Linux VM rather
  than macOS.
- **Container root is not a hard boundary.** The box user has `sudo` inside
  the container by design. Do not run code you actively distrust in a box and
  assume the host is unaffected.
- **A compromised sidecar can relay the box to the internet in userspace.**
  `--cap-drop=ALL` and `ip_forward=0` stop privilege escalation and kernel
  routing; neither is needed to copy bytes between two sockets. Under
  `--net limited` the box must be able to reach tinyproxy for the mode to
  function, so that surface is real. Under `--net none` the box cannot reach
  the sidecar at all, which is what protects a sealed box.
- **No log is tamper-evident.** Each component writes its own log, so a
  compromised one can log falsely or fall silent before any byte reaches the
  daemon. What it cannot do is alter or delete what was already written.
  Detecting a gap would need the record to leave the machine as it is
  produced, which boxy does not do.
- **`--net limited` gives the box something to attack.** tinyproxy is C code
  parsing input the box controls. `--net none` gives it nothing at all, and
  that difference is the honest distinction between the two modes.
