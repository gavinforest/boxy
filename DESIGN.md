# Design notes

Why boxy is built the way it is — and, for a fair number of these, what broke
when it was built the other way first.

Nothing here is required to *use* boxy. [README.md](README.md) covers what it
does and how to drive it, [TOUR.md](TOUR.md) shows it running against a live
daemon, and [SECURITY.md](SECURITY.md) covers what holds up when something is
compromised. This file is for anyone changing boxy, and for anyone who hit one
of these behaviours and wants to know whether it was deliberate.

[CLAUDE.md](CLAUDE.md) is the compressed version: the invariants alone, without
the reasoning. If you only want to know what not to break, read that instead.

---

## Contents

- [State and configuration](#state-and-configuration)
- [The network](#the-network)
- [The box interior](#the-box-interior)
- [The shell prompt](#the-shell-prompt)
- [Images](#images)
- [Output and logging](#output-and-logging)
- [Lifecycle](#lifecycle)
- [Testing](#testing)

---

## State and configuration

Everything the host hands a box, and how:

```
   host                                     container
   ────                                     ─────────
   <state>/boxy_ed25519.pub ──env─────────▶  ~boxyboy/.ssh/authorized_keys
   password (plaintext, 0600) ─┐
                               └─hash──────▶  chpasswd -e     (sudo only)
   <workdir or $TMPDIR/boxy/…> ──mount────▶  /work
   <repo>/.git  (worktree boxes only) ────▶  <repo>/.git   (same path)
   <state>/hostkeys ──────mount───────────▶  /etc/ssh/hostkeys
   127.0.0.1:2200 ────────publish─────────▶  :22  (sshd, key-only)
   127.0.0.1:<yours> ─────publish─────────▶  only what you pass to -p
```

Note what is *not* in that picture: an image build step, a config file inside
the container, and any state boxy keeps of its own. All three are deliberate.

### Configuration arrives at runtime

Keys, password hashes, proxy settings and UID/GID all arrive as environment at
`docker run` and are applied by `docker/entrypoint.sh`. One image serves every
box; rotating your keypair does not mean a rebuild, and `docker history`
reveals nothing.

The password is the sharpest case. boxy hashes it on the host with
`openssl passwd -6` and passes only the sha512-crypt hash as
`BOXY_PASSWORD_HASH`; the entrypoint feeds that to `chpasswd -e` and unsets the
variable. The plaintext never crosses the boundary, so it appears in no image
layer, no `docker inspect`, and no `/proc/<pid>/environ`. It is written
host-side to `<state>/instances/<name>/password` with mode 0600, which is where
`boxy password` reads it from.

There is no gap between container startup and complete configuration: the
entrypoint finishes its work before sshd accepts anything.

### Docker labels are the state store

Instance index, ports, workdir, network mode and user all live as `boxy.*`
labels on the container. There is no sidecar database to get out of sync with
reality — `docker rm` a box by hand and boxy simply stops seeing it.

This is what makes the docker passthroughs safe to skip. The container name is
the box name, so `docker logs boxy-1` works exactly as you would expect, and
boxy has no bookkeeping to update afterwards. The one thing to keep in mind is
that a box and its sidecar can get out of sync if you move only one of them.

### Labels record configuration; `boxy info` checks reality

A label records configuration at creation, so most of them cannot subsequently
be wrong: `ssh port` and `published` agree with `docker port` by construction,
`user`/`caps`/`created` are fixed for the life of the container, and `net` is a
property of the box's network that Docker enforces.

Three can drift, and each is checked on every `boxy info`:

|                        | Drifts when                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------- |
| `workdir`              | you delete or move the directory on the host — `/work` silently becomes an empty mount |
| repository of `branch` | you move the repository on the host (moves the object store)                           |
| `branch`               | you rename it on the host, or the box checks out another                               |

**Actual state is printed beside the label, never instead of it.** The label is
the initial configuration; printing both is what makes a divergence from it
visible rather than invisible.

All three are determined host-side, so the container cannot misrepresent
itself. `/work` and the git directory are bind mounts, so the host and the box
read the same bytes — a `git checkout` performed *inside* the box shows up
here, and the checks work on a stopped box.

> An earlier design checked `net` by running `ip route` inside the box. That was
> falsifiable, because the box owns every binary such a check could run: a box
> with `sudo` could shadow `ip` and report clean while egress worked. Isolation
> is now a property of the docker network rather than of the container, so
> network state does not depend on anything the box controls and cannot be
> spoofed from inside it.

### One knob for the config directory

`BOXY_CONFIG_DIR` moves the config file and the allowlist together. There is
deliberately **no separate variable for the config file**: two knobs would let
the pair come apart, with the config read from one directory and the allowlist
from another, and nothing to tell you it had happened.

**It can only come from the environment.** It names the directory holding the
file that configures boxy, so a value read *from* that file could never have
applied to finding it — by then boxy has already read it. Setting
`BOXY_CONFIG_DIR` inside your config is therefore circular, and boxy says so
and ignores that one line rather than letting it half-apply:

```
$ boxy config
warning: ignoring BOXY_CONFIG_DIR set inside ~/.config/boxy/config —
         it selects that file, so it must come from the environment
```

### `--init` takes a source, not a destination

`boxy config --init [FROM]` names the file to install **from**, and always
writes to the path boxy actually reads. A config written somewhere boxy does
not look would need a second step to matter, so making the argument a
destination would have created a way to "install" a config that does nothing.

It never overwrites. If a config or an allowlist is already there it writes
nothing and names both, because deciding what to do with them is yours.

---

## The network

### Isolation belongs to the network, not the container

Both restricted modes put the box on a `docker network create --internal`
network. Docker enforces the isolation: no default route is installed, no NAT
rule exists for the subnet, and external DNS resolution is dead.

Nothing about the isolation lives in the image or in the running container, so
there is no state to lose. Isolation survives a restart, a daemon restart, or
anything else that happens without boxy's involvement, and no step has to be
reapplied afterwards. Root inside the box cannot undo it either, because
`CAP_NET_ADMIN` is never granted:

```
$ sudo ip link add dummy0 type dummy
RTNETLINK answers: Operation not permitted
```

A consequence worth naming: **DNS is dead in an isolated box** without boxy
doing anything, which closes what would otherwise be a bidirectional covert
channel — data out in query labels, answers back in TXT records.
Container-name lookups still work, which is how the sidecar finds the box.

This is also why `boxy doctor` does not check whether an isolated box is still
isolated. There is nothing there to check. An earlier boxy applied isolation to
the running container and did need that check.

### Why the sidecar is created on a bridge first

Internal networks come with one Docker limitation: **Docker will not create a
host port binding for a container whose only network is internal.** `-p` is
accepted and silently discarded — no error, an empty binding list, and
`docker port` prints nothing.

So the order in which the sidecar acquires its two networks is load-bearing. It
is created with `docker run --network boxy-egress -p …`, where `boxy-egress` is
an ordinary bridge. At that moment its only network is a normal one, so Docker
binds the host ports without complaint. Only *afterwards* does boxy run
`docker network connect boxy-iso-<name>` to attach the box's internal network:

```
$ docker run -d --network some-internal-net -p 19999:80 …   # created on internal
$ docker port <container>
                                                            # nothing: discarded

$ docker run -d --network bridge -p 19998:80 …              # created on a bridge
$ docker port <container>
80/tcp -> 0.0.0.0:19998
$ docker network connect some-internal-net <container>      # attach internal after
$ docker port <container>
80/tcp -> 0.0.0.0:19998                                     # binding survives
```

Reverse those two steps and every published port on every isolated box
disappears, with nothing in any log to say why.

The same limitation is why `-p` cannot add a port to an isolated box after the
fact — the host bindings are fixed when the sidecar is created. `boxy forward`
is the answer there, and it works because it tunnels over ssh through the one
port the sidecar already binds. The sidecar's `socat` is a plain byte relay,
so it sees a single TCP connection and never learns that the forwarded port
exists; no new host binding and no sidecar restart are needed.

### The sidecar is a trust boundary

The sidecar is the one component deliberately on both sides, so be clear about
what its hardening does and does not buy. [SECURITY.md](SECURITY.md) is the
full treatment; the short version:

**It has full internet access, by design** — that is the entire reason it
exists. So a compromised sidecar defeats the isolation completely, and
`--cap-drop=ALL` and `ip_forward=0` do not prevent that. They stop privilege
escalation and *kernel* routing; relaying a TCP connection in userspace needs
neither, and the image ships `socat` and `tinyproxy` already.

**What actually protects a sealed box is reachability, not hardening.** Under
`--net none` the box has no way to talk to the sidecar at all — every port
closed, nothing listening on the private side — so there is no path from box to
sidecar to attack in the first place. The dropped capabilities are defence in
depth behind that, not the thing doing the work.

**Under `--net limited` the surface is real**, because the box must reach
tinyproxy for the mode to function. That is the meaningful difference between
the two modes: `--net none` gives the box nothing to attack, `--net limited`
gives it one thing.

An ingress-only sidecar (`--net none`) keeps no capabilities at all; a proxying
one (`--net limited`) gets exactly four back. `SETUID`, `SETGID` and `SETPCAP`
are tinyproxy's own privilege drop to its unprivileged user, and `KILL` belongs
to the supervisor — see below.

### Reloading the allowlist without dropping sessions

`boxy allow` widens a running box's egress in about three quarters of a second
without disturbing live ssh sessions or port forwards. That constraint is the
entire source of the design's complexity, because an isolated box's ssh port is
carried by `socat` inside the same sidecar the proxy lives in, and restarting
the container drops every session it is holding.

The box's copy of the policy is bind-mounted into the sidecar **read only** at
`/etc/boxy-proxy/allowlist.txt`. Two consequences follow: changing policy is a
host-side write plus one signal, so nothing is exec'd into the sidecar to move
it; and the sidecar cannot edit its own rules, so a compromised one has no way
to make a widening of its policy persist.

Two things make that read-only mount worth more than a gesture. The allowlist
is the *only* input to the filter, so there is no second file to point at
instead; and `socat` — the process on the receiving end of every inbound
connection, and so the most exposed thing in the sidecar — is dropped to
`nobody` with `setpriv`, specifically so a compromise there cannot kill
tinyproxy and stand up an unfiltered proxy in its place.

**tinyproxy has to be restarted, not signalled.** It compiles its filter list
once at startup. It does have a `SIGHUP` handler, but that only re-reads the
config file — signal it directly and it will cheerfully log
`Reloading config file finished` while continuing to enforce the old policy.

So the sidecar's PID 1 is the entrypoint script acting as a supervisor, rather
than tinyproxy itself: on `SIGHUP` it rebuilds the filter and restarts *only*
tinyproxy, leaving the socat listeners — and the ssh sessions riding them —
untouched. It bumps a counter at `/run/boxy-proxy-generation` each time, which
`boxy allow` reads before and after signalling, so the restart is confirmed
rather than assumed.

**The counter alone is not enough**, and the reason is worth knowing if you
ever build something similar. A bind-mounted write is **not instantly visible
inside the container** on Docker Desktop, where the mount crosses a virtual
filesystem into the VM rather than being the same kernel's page cache —
measured here as usually visible on the first read, occasionally not for the
better part of a second. Signalling immediately therefore let the supervisor
rebuild the filter from the *old* file, bump its generation, and report a
perfectly healthy reload of a policy nobody asked for. The counter could not
catch that: it confirms a restart happened, not that the restart read what you
wrote. So `boxy allow` waits until the sidecar can see the exact policy it just
wrote, and only then signals.

Two consequences of the sidecar's PID 1 being a shell are worth naming. It
needs `CAP_KILL`, because tinyproxy drops to its own user and signalling
another user's process is exactly what that capability governs — without it the
reload fails with `EPERM`. And it must trap `SIGTERM` itself, because the
kernel discards default-action signals sent to PID 1: an untrapped shell there
never hears `docker stop` and waits out the full ten-second grace period before
being killed.

### Allowlist entries compile to regexes

The sidecar compiles the list into POSIX extended regexes and escapes only
dots, so anything else with meaning in a regex would survive into the pattern
and widen the policy silently — `[^q]*` becomes `^(.*\.)?[^q]*$`, which matches
every domain there is.

That is why entries are validated as domains rather than accepted as patterns,
and why **every** way into the list is checked against the same rule: `--allow`,
`boxy allow`, and the file itself. Adding a fourth entry point without the
check would reopen it.

Subdomains are always included, which is why there is no wildcard syntax to get
wrong: `github.com` already covers `api.github.com`.

### Blocked HTTPS has no status code

A blocked HTTPS request shows up as `curl` exit 7 / status `000`, not a 403.
HTTPS goes through the proxy as `CONNECT` and tinyproxy refuses by dropping the
tunnel, so there is no HTTP response to carry a status. Plain HTTP does return
a real 403.

This is worth knowing mostly because it makes a blocked request look like a
network fault, which sends people looking in the wrong place.

---

## The box interior

### The login shell is zsh, and Debian's zsh reads no profile

The box user's login shell is zsh, which matters more than it sounds like it
should. Debian's `/etc/zsh/zprofile` is comments only; it never sources
`/etc/profile`, so a zsh login shell sees nothing in `/etc/profile.d`.

`PATH` and the proxy arrive regardless, because `sshd`'s pam_env reads
`/etc/environment`. But `cd /work` and the `boxy env` loader would not. The
entrypoint therefore writes those into `~/.zshenv`, which zsh reads on *every*
invocation, so one file covers both an interactive `ssh box` and a
non-interactive `ssh box cmd`. Bash needs two files for the same job.

Bash is still installed and still fully configured, and **`boxy exec` uses
`bash -l` deliberately** — a broken zsh startup file cannot lock you out.

### How `boxy env` reaches every entry path

`boxy env` keeps one file in the box, `/etc/boxy-env`, holding one `KEY=VALUE`
per line, and the entrypoint installs a loader at `/etc/profile.d/boxy-env.sh`
that reads it. There is no host-side copy and nothing replayed on start, so the
variables survive a restart untouched — and can be read back while the box is
stopped, since boxy lifts the file out with `docker cp` rather than needing
anything running to ask.

Getting that loader to run on every way in takes three files, because each
entry path reads a different one:

| Entry path              | Reached through                                                            |
| ----------------------- | -------------------------------------------------------------------------- |
| `ssh box` (interactive) | `~/.zshenv`, which sources `/etc/profile.d/*.sh` by hand                   |
| `ssh box cmd`           | `~/.zshenv` again — zsh reads it on *every* invocation                     |
| `boxy exec` (`bash -l`) | `/etc/profile.d/boxy-env.sh` directly, as a login shell                    |
| bash, if you switch     | a block at the **top** of `~/.bashrc`, above Debian's interactive guard    |

`ssh box cmd` is the awkward one: it is neither a login shell nor an
interactive one, so it reads no profile of its own. zsh's `~/.zshenv` covers it
for free. The bash equivalent does not come free — Bash has a special case for
shells started by sshd, but Debian ships
`case $- in *i*) ;; *) return;; esac` near the top of `.bashrc`, and the
non-interactive case returns before reaching anything below it. **boxy's block
must sit above that guard**, which is why the entrypoint prepends rather than
appends.

Values need no quotes: the loader uses `export "$line"`, which passes the whole
assignment as one argument, so `K=two words` works with nothing escaped.

`PATH` and `BOXY_*` are refused — `PATH` because replacing the box's own breaks
every command in it, `BOXY_*` because it is boxy's channel into the entrypoint.

### Why `-e` is not enough

A variable set with `docker run -e` lands in PID 1's environment, which the
box's own processes and `boxy exec` inherit. **An ssh session does not:** sshd
builds a fresh environment through PAM rather than inheriting PID 1's. And `-e`
is fixed for the life of the container, so adding a variable would mean
recreating the box.

That is the whole reason `boxy env` exists as a file rather than as a wrapper
around `-e`. It reaches every way in, and it works on a box that is already
running.

The rc and profile files run once, at session start, so a session that was
already open when you ran `boxy env` still has the old environment. Nothing
outside a shell can change a running shell's environment — a process cannot
write its parent's — so the refresh has to be something the session runs on
itself:

```bash
. /etc/profile.d/boxy-env.sh
```

The leading `.` is the shell's **source** command. It runs the file in the
*current* shell instead of forking a child, which is the entire point: a
child's exported variables die with the child, so
`bash /etc/profile.d/boxy-env.sh` would accomplish nothing at all.

### Capabilities are tuned for honest failures

`--caps minimal` drops the four capabilities nothing in a dev box legitimately
needs — `MKNOD`, `SETPCAP`, `SETFCAP`, `FSETID` — and keeps the other ten. The
ten it keeps are kept **deliberately**, because losing them produces confusing
failures rather than honest ones.

The sharpest example is `NET_RAW`:

```
$ ping -c1 127.0.0.1
exec /usr/bin/ping: operation not permitted
```

`/usr/bin/ping` carries the file capability `cap_net_raw=ep`. The `e`
(effective) bit means that when `NET_RAW` is outside the bounding set, `exec`
of the binary fails outright — not a degraded ping, a binary that will not
start, reporting an error that never mentions `NET_RAW`.

The sharp part is that ping does not even need the capability. The image sets
`net.ipv4.ping_group_range = 0 2147483647`, so any process can already open the
unprivileged ICMP datagram socket ping actually uses; no raw socket is
involved. The failure comes entirely from the `e` bit being checked at `exec`,
before the program runs and discovers it had another way.

`KILL` is the same kind of story — `sudo pkill` silently fails without it — as
are `NET_BIND_SERVICE` and `AUDIT_WRITE`. The set favours usability over
provable minimality, on the grounds that a capability policy people disable
wholesale because it produces inscrutable errors protects nothing.

### `--caps default` read backwards

The `docker-default` mode was originally spelled `default`, which named the set
you never got *by* default. That spelling is now rejected rather than quietly
accepted: the two readings differ by ten capabilities, so anyone writing
`default` to mean "whatever boxy does normally" is told they asked for the
opposite instead of being handed it.

Rejecting is right here precisely because both readings are plausible. An alias
would have made the common misreading silent.

---

## The shell prompt

The `crunch` prompt shows box name, conda env, time, working directory, git
branch and a clean/dirty mark:

```
web: (base) {14:22} /work:boxy/web ✓ $
```

**The box name comes first**, in magenta, because a prompt that looks like a
host prompt is how you end up running something in the wrong place — and with
two boxes open in adjacent tabs it is the only thing that tells them apart. It
comes from `$BOXY_NAME`, which reaches the shell through `sshd`'s pam_env.

conda's own `changeps1` is switched off in the image and the `(base)` marker is
rendered by `docker/zshrc` from `$CONDA_DEFAULT_ENV`. Otherwise conda would
prepend it at activation — which happens after `.zshrc` runs — and would always
take the leftmost slot ahead of the box name. It still tracks `conda activate`
live.

**There is no oh-my-zsh.** The theme needs three things from it: a colour
table, `git_prompt_info` and `ruby_prompt_info`. `docker/zshrc` defines them in
a dozen lines instead of carrying a framework clone in the image. That also
fixes a real failure — oh-my-zsh's `git_prompt_info` is asynchronous, filled in
by a `precmd` worker through `zle -F`, and in a box driven over SSH by a script
that worker frequently never delivers, so the branch simply never appears. The
version here is synchronous. The theme file itself is unmodified, so it stays
interchangeable with the same theme on a normal oh-my-zsh machine.

---

## Images

### Miniforge, not Miniconda

Miniforge defaults to the community-run **conda-forge** channel. Anaconda's own
`defaults` channel is covered by commercial terms of service that require a paid
licence for organisations over a certain size — conda-forge carries no such
condition, so an image built this way raises no licensing question wherever it
ends up.

### `matplotlib-base`, not `matplotlib`

conda-forge's `matplotlib` metapackage pulls the whole Qt6 GUI toolkit —
including static `.a` libraries — into a headless container reached over SSH.
`matplotlib-base` is the same plotting library without the interactive
backends; `Agg` still works, so `savefig()` and marimo/notebook rendering are
unaffected. This alone was several hundred MB.

### mamba stays

All of conda + mamba + rattler + libmambapy is 48 MB, and modern conda uses
libmamba as its solver anyway, so dropping it would slow installs and only save
about 2% of the image.

### Where the `INSTALL_*` ARGs sit

They are declared immediately above the `RUN` that reads them, **not** at the
top of the Dockerfile, because an `ARG` in scope contributes to every later
layer's cache key whether or not that layer uses it.

Declared at the top, `--claude` gave the `apt` layer a cache key no build had
ever produced, and re-downloaded the whole of Debian before reaching the one
`npm` line that actually differs. As written, all four variants share every
layer up to the point where they genuinely diverge, so building a second
variant costs only what it adds.

This is the single easiest thing to break by tidying the Dockerfile, and
nothing about it is visible in the output — a wrongly-placed `ARG` just makes
builds slow.

### Every image is named for what is in it

There is no `boxy:latest`, and nothing moves. `boxy build` writes
`boxy-base:latest`, `--extras` writes `boxy-extras:latest`, and so on; all four
can sit side by side.

A name always means one stack, so there is never a question of what you are
about to run. The cost is that building a variant does not silently become your
default — you say which one you want, once, via `--image` or `BOXY_IMAGE`.

`boxy images` lists every variant whether or not you have built it, because
"have I built the full one?" is not a question a list of what exists can
answer. `IN USE` counts rather than naming, because a bare `2` in that column
would read as `boxy-2` and a name list has no bounded width; `boxy images -v`
names them instead, and `boxy info` reports the image from the other end, per
box.

Each image carries a `boxy.variant` label, which is what identifies it if you
retag it or set `BOXY_IMAGE` to a name of your own.

---

## Output and logging

### Control characters are stripped from `boxy logs`

`boxy logs` is a docker passthrough with one deliberate exception: control
characters are stripped from its output.

A container chooses what goes into its own log — tinyproxy echoes the requested
domain into a denial line, sshd echoes the username of a failed login — so raw
`ESC` bytes in that text would let a box drive your cursor and paint over lines
already on screen. It cannot forge a log *line* (a bare CR truncates, and
`%0d%0a` is never decoded), so what is stored is honest either way; this is
only about what a terminal is asked to render.

**The filtering is not conditional on writing to a terminal**, because
`boxy logs -s web | grep refused` renders at the *end* of the pipeline and boxy
cannot see that far. `ESC` alone is removed, so an injected `[2A` stays in the
output as visible text rather than disappearing. `boxy logs --raw` (or
`docker logs` directly) gives the container's exact bytes.

### Ingress logging is split in two

The sidecar's container log is deliberately exception-only: the listeners it
placed, the allowlist it compiled, and every domain it later refused. The full
per-connection record — who connected, when, whether the box answered — is kept
separately and read with `boxy logs -v`.

The split exists because socat at `-dd` spends about a dozen lines on one
connection, which would bury everything else. Error-level lines are echoed back
into the container log so `boxy logs -s` still shows real faults on its own;
warnings are not, because "connection reset by peer" fires on every ordinary
close and would let anyone reaching a published port flood it.

The trail lives in a file inside the sidecar and is read with `docker cp`, so
it is still available after that sidecar has stopped — which is when a dead
relay most needs explaining.

---

## Lifecycle

### A failed create undoes itself

Everything up to port planning only reads. Past that, a failure can have
already made a git worktree and its branch, a scratch directory, and a state
directory holding the sudo password. All of it is undone, and boxy says so:

```
$ boxy create worktree -n web --net limited
adding worktree boxy/web to /Users/you/code/thing
Error response from daemon: all predefined address pools have been fully subnetted
warning: create failed; undoing what it had already made
  removed the worktree and branch boxy/web
```

**The one thing it will not undo is work.** The worktree is retired with plain
`git worktree remove`, which refuses on uncommitted changes, and the branch is
deleted only while it still points at the commit it was created from. A
directory you named with a path target is never touched — boxy did not make it.

### Worktree boxes share history and nothing else

A worktree's `.git` is a *file* holding an absolute path back to the main
repository's git directory. Mount only the worktree and the box has a broken
repo, so boxy also mounts that git directory at the identical path inside the
container. Your main checkout is not mounted — the box shares history and
nothing else, and cannot touch your working tree.

Because the object store is shared, a commit made in the box is in your
repository immediately: same objects, same refs, nothing to push or pull. It
also means **only committed content crosses over**, since a worktree is a
checkout of a commit rather than a copy of your working directory. That is the
most common first-run surprise; [README.md](README.md#worktree-boxes) has the
practical version.

**No credentials are involved.** The box commits locally against a mounted
object store. It holds no SSH key, so it can push nowhere.

The branch always survives `boxy rm`, because of that same shared object store
— it may hold the only copy of the work. Since branches persist and instance
names get reused, a second `boxy/boxy-1` becomes `boxy/boxy-1-2`.

### Docker's address pools are the real ceiling

Each `--net none` or `--net limited` box gets its own Docker network, and
Docker's default address pools run out somewhere around **two to three dozen**
of them. A create that hits the ceiling fails with the daemon's own message and
rolls back cleanly, but the ceiling is Docker's to raise
(`default-address-pools` in `daemon.json`), not boxy's. `docker network prune`
reclaims any that outlived their boxes.

This is the failure you are most likely to meet in normal use, and its error
text — `all predefined address pools have been fully subnetted` — says nothing
about boxes.

### A scratch workdir is printed once

Given no target, boxy makes a fresh directory under
`$TMPDIR/boxy/<name>.XXXXXX` with `mktemp`, so a recreated box never inherits a
previous one's leftovers. The path lives in a label on the container, so
removing the container is what loses it: it is printed at `boxy rm` and then
boxy forgets it. There is no later command that will tell you where a removed
box's scratch directory was.

boxy does not track, garbage-collect, or reason about the temp directory's
lifecycle at all — the OS reaps it on its own schedule.

---

## Testing

What the suites cover, and their current status, is [TOUR.md
§12](TOUR.md#12-test-status). One design consequence belongs here.

**Running the suite removes every boxy-managed container on the host**, and a
test-only naming scheme would not fix that. The suite tests boxy's own
behaviour rather than just its output, so it has to run `boxy create`, which
sets `boxy.managed=1` whatever the box is called. Several assertions are about
*global* daemon state besides — "the name may be omitted when exactly one box
exists" is only true, and only testable, when the daemon holds exactly one boxy
box.

A shared Docker daemon is the one resource the suite cannot sandbox. Everything
else it can: it runs against a scratch `BOXY_STATE_DIR` under `$TMPDIR` with
its own keypair, so it cannot touch a real install or your `~/.ssh`.

The claims in [SECURITY.md](SECURITY.md) marked *verified* are asserted by
`test/network.sh`, so they fail the suite if they stop being true.
