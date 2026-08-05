# boxy

Transparent SSH-reachable development containers with a Docker backend by Docker. Each box is a Debian
container with a preinstalled Python stack, a non-root user, a
known SSH keypair, a mounted working directory, published ports, and an
optional egress allowlist.

Network access is graded to `full` access, `limited` access ( HTTP Proxy sidecar container with allowlist), or `none` (runs a sidecar on a docker internal network for port forwarding / ssh).

```
$ cd ~/code/experiment && boxy create .
created instance 1 (boxy-1), ssh at port 2200

$ boxy create worktree
created instance 2 (boxy-2), ssh at port 2201
  branch  boxy/boxy-2   (shares history with /Users/you/code/experiment)

$ boxy ssh boxy-2
boxyboy@boxy-2:/work$
```

---

## Quick start

```bash
./boxy build          # builds boxy:latest and boxy-proxy:latest (~7 min, 2.3 GB)
./boxy config --init  # writes ~/.config/boxy/config and the egress allowlist
./boxy create .       # mount the current directory at /work
./boxy ls
./boxy ssh boxy-1
```

Put `boxy` on your `PATH` (a symlink is fine — it resolves its own directory
to find the `Dockerfile` and `docker/` directory alongside it):

```bash
ln -s "$PWD/boxy" /usr/local/bin/boxy
```

---

## How it works

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

Three key aspects of the design:

**Configuration arrives to container at runtime** Keys, password hashes, proxy
settings and UID/GID all arrive as environment at `docker run` and are applied
by `docker/entrypoint.sh`. One image serves every box; rotating your keypair
does not mean a rebuild, and `docker history` reveals nothing.

**Docker labels are the state store.** Instance index, ports, workdir, network
mode and user all live as `boxy.*` labels on the container. There is no
sidecar database to get out of sync with reality — `docker rm` a box by hand
and boxy simply stops seeing it.

**Container keys are persisted and pinned.** `<state>/instances/<name>/hostkeys` is
bind-mounted into the container, so each boxy container can read its own public host key (what it uses to identify itself) and `boxy` can write a real `known_hosts` entry. No trust-on-first-use prompt and
no `StrictHostKeyChecking=no`. (TODO: is this accurate?)

---

## Commands

**boxy commands** —

| Command                       | What it does                                          |
| ----------------------------- | ----------------------------------------------------- |
| `boxy create [options]`       | Create and start a box (see below)                    |
| `boxy ssh [NAME] [-- CMD]`    | Interactive session, or one command with `--`         |
| `boxy forward [NAME] [PORTS]` | Tunnel box ports to the _same_ localhost numbers      |
| `boxy rm NAME...`             | Remove a box; never touches your files                |
| `boxy ls`                     | List boxes with status, SSH port, net mode, workdir   |
| `boxy info [NAME]`            | One box in detail, config and actual state            |
| `boxy password [NAME]`        | Print the stored sudo password                        |
| `boxy env [NAME] [K=V]`       | Set/inject or list environment variables the box sees |
| `boxy ssh-config [--install]` | Emit / install an `ssh_config` covering every box     |
| `boxy build [--full]`         | Build the images                                      |
| `boxy doctor [--verbose]`     | Check the local setup; `-v` adds `boxy info` per box  |
| `boxy config [--init]`        | Show or scaffold configuration                        |

**Docker passthroughs** — thin wrappers that resolve the box name, add boxy's
defaults, and hand off to Docker. Added for convenience of use. If you prefer, run the bracketed command yourself; the
container name is the box name.

| Command                     | Wraps               | Why bother                                                                                                      |
| --------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `boxy exec [NAME] [CMD]`    | `docker exec`       | Sets the box user, `$HOME` and `/work`; works when SSH is broken. Needs a terminal only for the no-command form |
| `boxy logs [NAME] [-f]`     | `docker logs`       | The entrypoint's setup narration — the first place to look when a box misbehaves                                |
| `boxy start\|stop\|restart` | `docker start/stop` | Re-applies egress isolation and re-pins the host key on the way back up                                         |
| `boxy top [--watch]`        | `docker stats`      | Filters to boxy-managed containers                                                                              |

The name may be omitted whenever exactly one box exists. Proxy sidecars don't
count toward that — a single `--net limited` box still lets you omit it.

### `boxy create`

One positional argument says what lands in `/work`:

|                           |                                                    |
| ------------------------- | -------------------------------------------------- |
| `boxy create .`           | mount this directory                               |
| `boxy create ~/src/thing` | mount that directory                               |
| `boxy create worktree`    | a new git worktree of the repo you are standing in |
| `boxy create`             | a fresh scratch dir under `$TMPDIR/boxy`           |

`worktree` is a keyword. If you have a directory actually named `worktree`,
write `./worktree`.

```
-b, --ref REF         commit-ish the worktree branches from (default: HEAD)
-n, --name NAME       instance name (default: boxy-N)
    --password PASS   sudo password (default: random EFF passphrase)
-u, --user NAME       login user (default: boxyboy)
-k, --key PATH        public key to authorize (default: $BOXY_SSH_KEY.pub)
    --net MODE        full | none | limited   (default: full)
    --caps MODE       minimal | default capability set (default: minimal)
    --allow DOMAIN    extra allowed domain for --net limited (repeatable)
-p, --publish SPEC    publish a port: PORT or HOSTPORT:PORT (repeatable)
    --image IMG       image to run
    --cpus N          CPU limit
    --memory SIZE     memory limit, e.g. 8g
```

### Docker passthrough for `boxy create`:

`boxy create` culminates with a call to `docker run`. Everything in the `boxy create` call after `--` is handed to `docker run` unchanged:

```bash
boxy create . -- -v ~/data:/data --gpus all --shm-size 2g
```

This is why the `boxy create` option list above is short: boxy carries a flag only where it
adds something of its own. For example, `--publish` binds through the sidecar, `--net`
selects an isolation mode. Boxy leaves the rest to docker rather than wrapping each feature.

Passthrough flags are appended last, so where docker takes the final value of a
repeated flag, yours beats boxy's (`--cpus 1 -- --cpus 3` gives you 3). Flags that
docker accumulates instead — `-v`, `-e`, `--cap-add` — add to what boxy set.

Two things to know:

- **`--network` is refused.** boxy owns the network: `--net` picks it, the
  sidecar attaches to it, `boxy rm` tears it down, and `boxy info` reports
  isolation by reading it. Setting it without using boxy would leave all four
  describing a container that no longer exists.
- **`-e` does not reach `boxy ssh`.** This is a docker/image issue. Setting an environment variable with `-e` is visible to the box's own processes and `boxy exec`, but an ssh session builds a
  fresh environment through PAM and does not inherit PID 1's (which is what `-e` uses). Use `boxy env`
  below, which reaches both, and can inject environment variables after a container is running (TODO note here)

---

## Environment variables

```bash
boxy env boxy-1 API_KEY=secret REGION=us-east-1   # set
boxy env boxy-1                                   # list
boxy env boxy-1 --unset REGION                    # remove
```

Sets environment variables within the box. Visible to `ssh box cmd`, an interactive `ssh box`, and `boxy exec` alike, and
they survive `boxy stop` / `boxy start`.

It is one file in the box, `/etc/boxy-env`, holding one `KEY=VALUE` per line. They're readable by processes in the following way:

|                         | reached via                                                                     |
| ----------------------- | ------------------------------------------------------------------------------- |
| `ssh box cmd`           | custom `~/.bashrc` reads it, even non-interactively when sshd started the shell |
| `ssh box` (interactive) | custom `/etc/profile.d/boxy-env.sh` reads it and runs by default                |
| `boxy exec`             | "                                                                               |

Implementation: `ssh box cmd` is the awkward one: it reads no profile and no rc of its own.
Bash has a special case for shells started by sshd, and boxy's block sits at
the _top_ of `~/.bashrc`, above the `case $- in *i*) ;; *) return;; esac` guard
Debian ships — below it, the non-interactive case returns before ever reaching
the block.

There is no host-side copy and nothing replayed on start. `/etc/boxy-env`, `~/.bashrc`, `/etc/profile.d/boxy-env.sh` live in the
container and survive a restart untouched. Values
don't need quotes either: the loader uses `export "$line"`, which passes the
whole assignment as one argument, so `K=two words` works with nothing escaped.

### Limitations:

`PATH` and `BOXY_*` are refused — `PATH` because replacing the box's own breaks
every command in it, `BOXY_*` because it is boxy's channel into the entrypoint.

### Picking up a change without reconnecting

The rc and profile files run once, at session start, so a session that was
already open when you ran `boxy env` still has the old environment. Nothing
outside a shell can change a running shell's environment — a process cannot
write its parent's — so the refresh has to be something the session runs on
itself:

```bash
. /etc/profile.d/boxy-env.sh
```

The leading `.` is the shell's **source** command (`source` is bash's alias for
the same builtin; `.` is the POSIX spelling). It runs the file in the _current_
shell instead of forking a child, which is the entire point: a child's exported
variables die with the child, so `bash /etc/profile.d/boxy-env.sh` (TODO: why not just use the `~/.bashrc`? Easier to remember) would
accomplish nothing at all. `.` means "here", not "over there".

---

## The working directory

```bash
boxy create .              # mount a directory you own
boxy create worktree       # a fresh branch of the repo you are in
boxy create                # fresh scratch dir in $TMPDIR/boxy/
```

When `boxy create` is called with a path, that directory is mounted at `/work` as-is. boxy will not copy it, move it, or delete it. For example, `boxy create .` mounts the hosts current directory into the container at `/work`. Changes are visible to the host, but deleting the container does **not** delete the current directory.

Given nothing, boxy makes a fresh scratch directory under
`$TMPDIR/boxy/<name>.XXXXXX` (uses `mktemp`, so a recreated box never inherits a
previous one's leftovers). Boxy remembers where it is, but the OS reaps
temp directories on its own schedule; boxy does not track, garbage-collect, or
reason about that lifecycle at all.

For these reasons, `boxy rm` is straightforward:

```bash
$ boxy rm boxy-1
removed boxy-1
  workdir left for the OS to reap: /var/folders/…/T/boxy/boxy-1.VUiiNA

$ boxy rm mine
removed mine
  your directory is untouched: /Users/gavin/code/thing
```

`boxy rm` deletes the container and boxy's per-instance bookkeeping — its host key,
`known_hosts`, and password file. Your files are either in the named directory given to `boxy create` (or volumes you mounted yourself), or sitting in the temp area (TODO: though `boxy` will forget where?)

---

## Worktree boxes

```bash
$ cd ~/code/thing
$ boxy create worktree
  workdir /var/folders/…/T/boxy/boxy-1.k3Xq2v -> /work
  branch  boxy/boxy-1   (shares history with /Users/you/code/thing)
```

The box gets a real git worktree on its own branch, checked out from `HEAD`
(or from `--ref`). Commit inside the box and the commit is in your repository
immediately — same objects, same refs, nothing to push or pull:

```bash
$ boxy ssh boxy-1 -- 'cd /work && git commit -am wip'
$ git log --oneline boxy/boxy-1     # on the host, right away
```

**How.** A worktree's `.git` is a _file_ holding an absolute path back to the
main repository's git directory. Mount only the worktree and the box has a
broken repo, so boxy also mounts that git directory at the identical path
inside the container. Your main checkout is not mounted — the box shares
history and nothing else, and cannot touch your working tree.

**No credentials are involved.** The box commits locally against a mounted
object store. It holds no SSH key, so it can push nowhere; pushing is something
you do from the host afterwards.

**`boxy rm` keeps your work.** It runs `git worktree remove`, which refuses on
uncommitted changes — a dirty tree is reported and left alone:

```bash
$ boxy rm boxy-1
removed boxy-1
  worktree has uncommitted changes — left at /var/folders/…/boxy-1.k3Xq2v
  keep it, or discard it with:
    git -C /Users/you/code/thing worktree remove --force /var/folders/…/boxy-1.k3Xq2v
```

The branch always survives `boxy rm` (because of the shared objeect store); it may hold the only copy of the work.
Because branches persist and instance names get reused, a second `boxy/boxy-1`
becomes `boxy/boxy-1-2`.

---

## Docker container labels vs actual state

Boxy's stores state in containers' Docker labels, and a label records configuration at creation. Most cannot subsequently be wrong: `ssh port` and `published`
agree with `docker port` by construction, `user`/`caps`/`created` are fixed for
the life of the container, and `net` is a property of the box's network that
Docker enforces. Three can drift, and each are checked on every `boxy
info` call:

|                        | Drifts when                                                                            |
| ---------------------- | -------------------------------------------------------------------------------------- |
| `workdir`              | you delete or move the directory on the host — `/work` silently becomes an empty mount |
| repository of `branch` | you move the repository on the host (moves the object store)                           |
| `branch`               | you rename it on the host, or the box checks out another                               |

```bash
$ boxy info web
workdir     /var/folders/…/web.k3Xq2v -> /work   ⚠ MISSING on the host
branch      boxy/web in /Users/you/code/thing
            ⚠ now on 'renamed-behind-boxy'
net         none   (enforced by docker: boxy-iso-web is internal)
```

**Actual state is printed beside the label, never instead of it.** The label is initial configuration; this detects divergences from the initial configuration as well.

All three are determined on the host side (the container cannot misrepresent itself) — `/work` and the git directory are bind
mounts, so the host and the box read the same bytes. A `git checkout` performed
_inside_ the box shows up here, and the checks work on a stopped box.

> An earlier design checked `net` by running `ip route` inside the box. This was potentially falsifiable because the box owns every binary such a check could
> run: a box with `sudo` could shadow `ip` and report clean while egress
> worked. Isolation is now a property of the
> docker network instead of the container, so network state doesn't depend on the box, and is therefore not falsifiable.

## Controlling internet access

```bash
boxy create --net full      # default: ordinary bridge, unrestricted, no sidecar
boxy create --net none      # sealed: internal network, nothing in or out to host except through a sidecar
boxy create --net limited   # sealed + an allowlisting proxy sidecar
```

Both restricted modes put the box on a `docker network create
--internal` network. Docker is responsible for enforcing
the isolation: no default route is installed, no NAT rule exists for the subnet, and
external DNS resolution is dead. Nothing is applied to the running container (TODO: there is some configuration while building the image?),
so there is no state: isolation survives a restart, a daemon restart,
or anything else that happens without boxy's involvement.

Root inside the box cannot undo configuration, because `CAP_NET_ADMIN` is never granted:

```
$ sudo ip link add dummy0 type dummy
RTNETLINK answers: Operation not permitted
```

### The sidecar

Docker internal networks cause a slight hiccup on the Docker side. Unfortunately, **Docker will not create a host port
binding for a container only on an internal network (TODO: without inter-container communication allowed? plus "on" is vague in previous sentence).** `-p` is accepted and
silently discarded, and `docker port` reports nothing. Accordingly, in `boxy` the container publishes
nothing itself; a per-box sidecar — the only container on both the box's
network and an ordinary bridge (TODO what does ordinary bridge mean?) — carries traffic in both directions:

- **ingress**: `socat` listeners that hold the box's published ports, including
  SSH. This is what keeps `boxy ssh`, `boxy forward`, `scp` and `-p` working on
  a sealed box.
- **egress**:
  - `--net limited`: tinyproxy, refusing any domain not in
    `~/.config/boxy/allowlist.txt`.
  - `--net none`: none.

**When `--net none`, there is still a sidecar, but it is not a way out of the box.** Traffic only ever flows host →
sidecar → box, and the sidecar never accepts a connection _from_ the
box. The sidecar's listeners bind to its outward address alone and the private side is
left bare. From inside a box, every port on the sidecar is closed — by IP and
by name — and it cannot be used as a router even when handed an explicit
default route pointing at it. It runs with `--cap-drop=ALL` and
`net.ipv4.ip_forward=0`, so it has nothing to escalate to and cannot forward, TODO were it to be compromised.

Under `--net limited` the box _does_ reach the proxy port, necessarily, and it is the one listener exposed to the box.

The entrypoint exports `HTTP_PROXY`/`HTTPS_PROXY` (into `/etc/environment`, so
even non-interactive SSH commands see them), points `git`'s HTTP transport at
the proxy, and installs a `ProxyCommand` so `git@github.com` still works over
a CONNECT tunnel.

```bash
boxy create worktree --net limited --allow example.com
docker logs boxy-sidecar-boxy-1     # every denial is logged here
#   NOTICE  Proxying refused on filtered domain "example.com"
```

(TODO: there should be a boxy wrapper for `docker logs boxy-sidecar..., and in general maybe it should be possible to inspect the sidecar?)

The shipped allowlist covers PyPI, conda-forge, GitHub, npm, Debian, Hugging
Face and the Anthropic API. Edit the file; it is read at box creation. TODO: what about adding to the allowlist while it's running? Or is that not covered? Maybe it would require shutting down the sidecar and rebooting it?

One quirk worth knowing when testing this yourself: a _blocked HTTPS_ request
shows up as `curl` exit 7 / status `000`, not a 403. HTTPS goes through the
proxy as `CONNECT`, and tinyproxy refuses by dropping the tunnel — there is no
HTTP response to carry a status. Plain HTTP does return a real 403.

---

## Passwords

The default `sudo` password is four words from the EFF long (7776-word) list —
about 51.7 bits of entropy, and easy to read aloud or paste.

**The plaintext never enters the container.** boxy hashes it on the host with
`openssl passwd -6` and passes only the sha512-crypt hash as
`BOXY_PASSWORD_HASH`; the container entrypoint feeds that to `chpasswd -e` and unsets the environment variable. The plaintext is written to `~/.local/share/boxy/instances/<name>/password`
with mode 0600, which is where `boxy password` reads it from, so it stays
host-side and injectable into whatever session needs it.

```bash
boxy password boxy-1
# thicken-earlobe-composed-shrunk
```

The password gates `sudo` only. **sshd never accepts passwords** —
`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`.
A box on a public interface cannot be brute-forced into.

---

## Using a box as a remote (Claude, VS Code, rsync, …)

`boxy` regenerates a standalone `ssh_config` on every create/remove (TODO: is it valid across all boxy instances?):

```bash
boxy ssh-config              # print it
boxy ssh-config --install    # Include it from ~/.ssh/config
```

After `--install`, `ssh boxy-1` works from anything that speaks SSH, including
Claude Code's remote workflows, `scp`, `rsync`, and VS Code Remote-SSH. Each
entry pins `IdentityFile`, `IdentitiesOnly yes`, a per-instance
`UserKnownHostsFile`, and `StrictHostKeyChecking yes`.

The image also ships Claude Code itself (`INSTALL_CLAUDE_CODE=1`), so you can
work from _inside_ the box against the mounted volume when that suits better.

---

## Container privileges

Two knobs, both aimed at the VPS (TODO: this is outdated) rather than your laptop.

### `--caps minimal` (the default)

Drops the four capabilities nothing in a dev box legitimately needs — `MKNOD`,
`SETPCAP`, `SETFCAP`, `FSETID` — keeping the other ten.

The ones it keeps are kept **deliberately**, because losing them produces
confusing failures rather than honest ones. The sharpest example: dropping `CAP_NET_RAW` causes `ping` to fail

```
$ ping -c1 127.0.0.1
exec /usr/bin/ping: operation not permitted
```

because `/usr/bin/ping` carries the file capability `cap_net_raw=ep`. The `e`
(effective) bit means that if `NET_RAW` is outside the bounding set, `exec`
of the binary **fails outright** instead of degrading the `ping`.
`KILL` (without it `sudo pkill` fails), `NET_BIND_SERVICE` and `AUDIT_WRITE`
are kept for the same reason.

If something ever fails in a way that smells like a missing privilege:

```bash
boxy create --caps default          # Docker's full 14
```

(TODO: we need to rewrite this because `--caps default` is not, in fact, the default. Perhaps `docker-default` is a better name instead of `default`?)

That's the fastest way to confirm or rule out capabilities as the cause. You
can also add a single capability via `BOXY_MINIMAL_CAPS` instead of abandoning
the reduced set. (TODO: what does this mean, editing the source code? Or setting an environment variable?)

---

## Configuration

`~/.config/boxy/config`, sourced as bash. See `boxy.conf.example` for the full
annotated set. Precedence from lowest to highest: defaults → config file → `BOXY_*` environment →
flags.

Most-used knobs:

| Variable         | Default                              |                                                 |
| ---------------- | ------------------------------------ | ----------------------------------------------- |
| `BOXY_SSH_KEY`   | `<state>/boxy_ed25519`               | keypair authorized on every box                 |
| `BOXY_USER`      | `boxyboy`                            | login user                                      |
| `BOXY_PORTS`     | `2718 8888 8000 8080 3000 5000 6006` | what `boxy forward` tunnels (TODO: by default?) |
| `BOXY_BIND_ADDR` | `127.0.0.1`                          | interface for published ports                   |
| `BOXY_NET`       | `full`                               | default egress policy                           |

---

## What's in the image

Debian bookworm, Miniforge (conda-forge channels — no Anaconda ToS
entanglement (TODO: whats this about ToS?)), Python 3.12. **2.3 GB.**

Default build includes:

`numpy` · `scipy` · `pandas` · `matplotlib-base` · `jax[cpu]` · `marimo` ·
`ipython` · `uv` · `mamba`/`conda` · `nodejs` · `git` · `git-lfs` · `tmux` ·
`ripgrep` · `fd` · `jq` · `htop` · `build-essential`

(TODO: seperate out installed and `uv` packages installed).
Opt-in, because they are large and not everyone wants them in every box:

```bash
boxy build --extras   # jupyterlab polars pyarrow scikit-learn   (+462 MB)
boxy build --claude   # @anthropic-ai/claude-code                (+291 MB)
boxy build --full     # both
```

Installing on a running container is ok too: the conda prefix is owned by the box user, so
`pip install` / `uv pip install` / `mamba install` all work at runtime without
`sudo`. (TODO: what about `conda install`? Also what's up with `uv pip install`? I don't use `mamba install` myself)

Two notes on the default package choices:

- Installed **`matplotlib-base`, not `matplotlib`.** conda-forge's `matplotlib`
  metapackage pulls the whole Qt6 GUI toolkit — including static `.a`
  libraries — into a headless container reached over SSH. `matplotlib-base` is
  the same plotting library without the interactive backends; `Agg` still
  works, so `savefig()` and marimo/notebook rendering are unaffected. This
  alone was several hundred MB.
- **mamba is a conda dependency.** All of conda + mamba + rattler + libmambapy is 48 MB, and
  modern conda uses libmamba as its solver anyway, so dropping it would slow
  installs and only save ~2% of the image.

Builds for `linux/amd64` and `linux/arm64` from the same Dockerfile. JAX is
CPU-only; for GPU you would add a CUDA build target and `jax[cuda12]`.

---

## Security notes

- SSH is key-only. Passwords exist for `sudo` and are never accepted by sshd.
- Published ports bind to loopback by default.
- **In general, the kernel is shared**, so a kernel privilege-escalation bug escapes
  everything above at once — namespaces, cgroups, seccomp and capabilities are
  all enforced by the thing that just got compromised. On Docker Desktop this
  is luckily not the case: containers run against the VM's kernel, so an escape lands in a disposable Linux VM, not on macOS.
- The box user has `sudo` **inside the container**. A container root is not a
  host root, but it is not a hard boundary either — do not run code you
  actively distrust in a box and assume the host is safe.
- No git credentials ever enter a box. A worktree box shares your repository's
  object store, so it can commit; it holds no key and can push nowhere.
- `--net none` and `--net limited` hold up against the box user because the
  isolation is not in the container at all: the box's network is created
  `--internal`, so Docker installs no route and no NAT for it. There is
  nothing inside to switch off, and `CAP_NET_ADMIN` is never granted, so
  `sudo ip link add` fails.
- **DNS is dead in an isolated box**, without boxy doing anything: an
  internal network resolves no external name, closing what would otherwise be
  a bidirectional covert channel (data out in query labels, back in TXT
  records). Container-name lookups still work, which is how the sidecar finds
  the box.
- **The sidecar is not reachable from the box.** It is dual-homed, so it would
  be the obvious thing to attack, but traffic only flows host → sidecar →
  box, so its listeners bind to its outward address and the private side is
  bare. Verified from inside a box: every port closed by IP and by name, and
  no egress even when given a default route pointing at it. The sidecar holds no
  capabilities (`--cap-drop=ALL`) and has `ip_forward=0`, so it cannot be
  turned into a router.
- Boxes cannot reach each other: each isolated box gets its own subnet with no
  route between them.
- **What an isolated box cannot do:** reach the internet, reach the host, or
  reach another box.
- **What it can do:** anything it likes with it's working directory (and local git dir), and its allowed network access. . Concretely:
  - Your `-d` directory is mounted read-write. Code in the box can read,
    modify or encrypt it.
  - A worktree box has your repository's git dir mounted read-write. Code in
    the box can rewrite branches and delete objects in your real repo. It has
    no credentials, so it cannot reach a remote — the blast radius is local.
  - Under `--net limited`, the allowlist constrains _where_ the box can talk, but not
    _what_ it can say. A `POST` from inside a limited box reaches
    `api.github.com` and gets a real response. Any allowlisted host that
    accepts uploads is a data path out.
- Capabilities are reduced by default (`BOXY_CAPS=minimal`, 10 of Docker's 14)
  but tuned for usability over provable minimality — see the config file for
  which are kept and why.
- **Nothing has to be reapplied after restarts.** Isolation belongs to the network, not to
  the running container, so a restart — by you, by the daemon, or by anything
  else — cannot lose it. `BOXY_RESTART` still defaults to `no`, now purely so a box
  you forgot to remove does not come back on its own. (TODO: what do you mean "come back on its own"?)
- `--net none` and `--net limited` hold up against the box user: the network
  is internal and `CAP_NET_ADMIN` is never granted. What they do not defend
  against is a container escape. They're a strong guardrail, and stop dependencies phoning home, but not a sandbox for
  hostile code.
- There is no gap between container startup (completion of entrypoint) and complete configuration.

---

## Troubleshooting

**`boxy doctor`** first — it checks the daemon, images, keys and wordlist
cache, and flags any isolated box that has lost its isolation. Add
`--verbose` for a full `boxy info` on every box.

**Box created but SSH times out.** Read `boxy logs <name>`; the entrypoint
narrates every step. Then `boxy exec <name>`, which uses `docker exec` and
does not depend on SSH at all.

**A `--net limited` box can't reach something it should.** `docker logs
boxy-sidecar-<name>` names every refused domain. Add it to
`~/.config/boxy/allowlist.txt` (applies to boxes created afterwards) or pass
`--allow` on the next `create`. Remember that a blocked HTTPS request looks
like a timeout/`000`, not a 403.

**An isolated box is unreachable over SSH.** Its ports live on the sidecar,
so check that one first: `docker logs boxy-sidecar-<name>` should report the
listeners it placed. If it exited, the box itself is fine and still reachable
with `boxy exec <name>`.

**Permission errors on a mounted volume (Linux hosts).** boxy passes your
host UID/GID and the entrypoint remaps the box user to match. If you mounted a
tree owned by someone else, that will not help; `chown` it or mount elsewhere.

**`git` in a worktree box says "not a git repository".** The box needs the
shared git dir mounted at the same absolute path the worktree's `.git` file
names. `boxy info NAME` shows the branch and repo; check that the repo still
exists at that path and was not moved after the box was created.
