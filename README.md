# boxy

Disposable, SSH-reachable dev boxes backed by Docker. Each box is a Debian
container with a preinstalled scientific Python stack, a non-root user, a
known SSH keypair, a mounted working directory, published ports, and an
optional egress allowlist.

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

Three things are worth calling out because they drive most of the design:

**Nothing is baked into the image.** Keys, password hashes, proxy
settings and UID/GID all arrive as environment at `docker run` and are applied
by `docker/entrypoint.sh`. One image serves every box; rotating your keypair
does not mean a rebuild, and `docker history` reveals nothing.

**Docker labels are the state store.** Instance index, ports, workdir, network
mode and user all live as `boxy.*` labels on the container. There is no
sidecar database to get out of sync with reality — `docker rm` a box by hand
and boxy simply stops seeing it.

**Host keys are persisted and pinned.** `<state>/instances/<name>/hostkeys` is
bind-mounted into the container, so boxy can read the box's public host key
directly off disk and write a real `known_hosts` entry. You get full host key
verification from the very first connection — no trust-on-first-use prompt and
no `StrictHostKeyChecking=no`.

---

## Commands

**boxy's own commands** — things that do not exist without boxy:

| Command | What it does |
| --- | --- |
| `boxy create [options]` | Create and start a box (see below) |
| `boxy ssh [NAME] [-- CMD]` | Interactive session, or one command |
| `boxy forward [NAME] [PORTS]` | Tunnel box ports to the *same* localhost numbers |
| `boxy rm NAME...` | Remove a box — never touches your files |
| `boxy ls` | List boxes with status, SSH port, net mode, workdir |
| `boxy info [NAME]` | One box in detail, checked against reality |
| `boxy password [NAME]` | Print the stored sudo password |
| `boxy ssh-config [--install]` | Emit / install an `ssh_config` covering every box |
| `boxy build [--full]` | Build the images |
| `boxy doctor [--verbose]` | Check the local setup; `-v` adds `boxy info` per box |
| `boxy config [--init]` | Show or scaffold configuration |

**Docker passthroughs** — thin wrappers that resolve the box name, add boxy's
defaults, and hand off. If you prefer, run the bracketed command yourself; the
container name *is* the box name.

| Command | Wraps | Why bother |
| --- | --- | --- |
| `boxy exec [NAME] [CMD]` | `docker exec` | Sets the box user, `$HOME` and `/work`; works when SSH is broken. Needs a terminal only for the no-command form |
| `boxy logs [NAME] [-f]` | `docker logs` | The entrypoint's setup narration — the first place to look when a box misbehaves |
| `boxy start\|stop\|restart` | `docker start/stop` | Re-applies egress isolation and re-pins the host key on the way back up |
| `boxy top [--watch]` | `docker stats` | Filters to boxy-managed containers |

The name may be omitted whenever exactly one box exists. Proxy sidecars don't
count toward that — a single `--net limited` box still lets you omit it.

### `boxy create`

One positional argument says what lands in `/work`:

| | |
| --- | --- |
| `boxy create .` | mount this directory |
| `boxy create ~/src/thing` | mount that directory |
| `boxy create worktree` | a new git worktree of the repo you are standing in |
| `boxy create` | a fresh scratch dir under `$TMPDIR/boxy` |

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
-v, --volume SRC:DST  extra bind mount (repeatable)
-e, --env K=V         extra environment variable (repeatable)
    --image IMG       image to run
    --cpus N          CPU limit
    --memory SIZE     memory limit, e.g. 8g
```

---

## The working directory

```bash
boxy create .              # mount a directory you own
boxy create worktree       # a fresh branch of the repo you are in
boxy create                # fresh scratch dir in $TMPDIR/boxy/
```

Given a path, that directory is mounted at `/work` as-is. boxy never creates
it, never moves it, and never deletes it.

Given nothing, boxy makes a fresh scratch directory under
`$TMPDIR/boxy/<name>.XXXXXX` (`mktemp`, so a recreated box never inherits a
previous one's leftovers) and then **stops caring about it**. The OS reaps
temp directories on its own schedule; boxy does not track, garbage-collect, or
reason about that lifecycle at all.

Which means `boxy rm` is uncomplicated:

```bash
$ boxy rm boxy-1
removed boxy-1
  workdir left for the OS to reap: /var/folders/…/T/boxy/boxy-1.VUiiNA

$ boxy rm mine
removed mine
  your directory is untouched: /Users/gavin/code/thing
```

It deletes the container and boxy's per-instance bookkeeping — host key,
`known_hosts`, password file — none of which mean anything once the box is
gone. There is no `--purge`, no confirmation prompt, and no state kept "just
in case", because nothing it removes is yours. Your files are either in a
directory you named, or sitting in the temp area where you can still get at
them.

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

**How.** A worktree's `.git` is a *file* holding an absolute path back to the
main repository's git directory. Mount only the worktree and the box has a
broken repo, so boxy also mounts that git directory at the identical path
inside the container. Your main checkout is not mounted — the box shares
history and nothing else, and cannot touch your working tree.

**No credentials are involved.** The box commits locally against a mounted
object store. It holds no SSH key, so it can push nowhere; pushing is something
you do from the host afterwards. This is why boxy has no git-key handling at
all.

**`boxy rm` keeps your work.** It runs `git worktree remove`, which refuses on
uncommitted changes — a dirty tree is reported and left alone:

```bash
$ boxy rm boxy-1
removed boxy-1
  worktree has uncommitted changes — left at /var/folders/…/boxy-1.k3Xq2v
  keep it, or discard it with:
    git -C /Users/you/code/thing worktree remove --force /var/folders/…/boxy-1.k3Xq2v
```

The branch always survives `boxy rm`; it may hold the only copy of the work.
Because branches persist and instance names get reused, a second `boxy/boxy-1`
becomes `boxy/boxy-1-2`.

---

## Labels vs reality

Docker labels are boxy's state store, and a label records **what you asked for
at create time**. Most cannot subsequently be wrong: `ssh port` and `published`
agree with `docker port` by construction, `user`/`caps`/`created` are fixed for
the life of the container, and `net` is a property of the box's network that
Docker enforces. Three can drift, and all three are checked on every `boxy
info`:

| | Drifts when |
| --- | --- |
| `workdir` | you delete or move the directory — `/work` silently becomes an empty mount |
| `branch` repo | you move the repository |
| `branch` | you rename it, or the box checks out another |

```bash
$ boxy info web
workdir     /var/folders/…/web.k3Xq2v -> /work   ⚠ MISSING on the host
branch      boxy/web in /Users/you/code/thing
            ⚠ now on 'renamed-behind-boxy'
net         none   (enforced by docker: boxy-iso-web is internal)
```

**Reality is printed beside the label, never instead of it.** The label is what
you asked for and the divergence is the news; quietly rewriting one to match
the other would erase the thing worth reporting.

All three are answered entirely on the host — `/work` and the git dir are bind
mounts, so the host and the box read the same bytes. A `git checkout` performed
*inside* the box shows up here, and the checks work on a stopped box. Nothing
enters the container, so there is no flag to opt out of, no cost worth
measuring, and nothing a box could lie about.

> An earlier design checked `net` by running `ip route` inside the box. That is
> gone, and worth recording why: the box owns every binary such a check could
> run, so a box with `sudo` could shadow `ip` and report clean while egress
> worked — demonstrated, not theoretical. Isolation is now a property of the
> network instead of the container, so there is no longer anything to ask the
> box about.

## Controlling internet access

```bash
boxy create --net full      # default: ordinary bridge, unrestricted
boxy create --net none      # sealed: nothing in or out except through the sidecar
boxy create --net limited   # sealed + an allowlisting proxy
```

Both restricted modes put the box **alone on a `docker network create
--internal` network**. That is the whole of the isolation, and Docker enforces
it: no default route is installed, no NAT rule exists for the subnet, and
external DNS resolution is dead. Nothing is applied to the running container,
so there is no state to lose — isolation survives a restart, a daemon restart,
or anything else that happens without boxy's involvement.

Root inside the box cannot undo it, because `CAP_NET_ADMIN` is never granted:

```
$ sudo ip link add dummy0 type dummy
RTNETLINK answers: Operation not permitted
```

### The sidecar

An internal network has one consequence: **Docker will not create a host port
binding for a container whose only network is internal.** `-p` is accepted and
silently discarded, and `docker port` reports nothing. So the box publishes
nothing itself, and a per-box sidecar — the only container on both the box's
network and an ordinary bridge — carries traffic in both directions:

- **ingress**: `socat` listeners that hold the box's published ports, including
  SSH. This is what keeps `boxy ssh`, `boxy forward`, `scp` and `-p` working on
  a sealed box.
- **egress** (`--net limited` only): tinyproxy, refusing any domain not in
  `~/.config/boxy/allowlist.txt`.

**The sidecar is not a way into the box.** Traffic only ever flows host →
sidecar → box, so the sidecar never needs to accept a connection *from* the
box. Its listeners bind to its outward address alone and the private side is
left bare. From inside a box, every port on the sidecar is closed — by IP and
by name — and it cannot be used as a router even when handed an explicit
default route pointing at it. It runs with `--cap-drop=ALL` and
`net.ipv4.ip_forward=0`, so it has nothing to escalate to and cannot forward.

Under `--net limited` the box *does* reach the proxy port, necessarily — that
is what `limited` means, and it is the one listener exposed to the box.

The entrypoint exports `HTTP_PROXY`/`HTTPS_PROXY` (into `/etc/environment`, so
even non-interactive SSH commands see them), points `git`'s HTTP transport at
the proxy, and installs a `ProxyCommand` so `git@github.com` still works over
a CONNECT tunnel.

```bash
boxy create worktree --net limited --allow example.com
docker logs boxy-sidecar-boxy-1     # every denial is logged here
#   NOTICE  Proxying refused on filtered domain "example.com"
```

The shipped allowlist covers PyPI, conda-forge, GitHub, npm, Debian, Hugging
Face and the Anthropic API. Edit the file; it is read at box creation.

One quirk worth knowing when testing this yourself: a *blocked HTTPS* request
shows up as `curl` exit 7 / status `000`, not a 403. HTTPS goes through the
proxy as `CONNECT`, and tinyproxy refuses by dropping the tunnel — there is no
HTTP response to carry a status. Plain HTTP does return a real 403.

---

## Passwords

The default password is four words from the EFF long (7776-word) list —
about 51.7 bits of entropy, and easy to read aloud or paste.

**The plaintext never enters the container.** boxy hashes it on the host with
`openssl passwd -6` and passes only the sha512-crypt hash as
`BOXY_PASSWORD_HASH`; the entrypoint feeds that to `chpasswd -e` and unsets
it. The plaintext is written to `~/.local/share/boxy/instances/<name>/password`
with mode 0600, which is where `boxy password` reads it from — so it stays
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

`boxy` regenerates a standalone `ssh_config` on every create/remove:

```bash
boxy ssh-config              # print it
boxy ssh-config --install    # Include it from ~/.ssh/config
```

After `--install`, `ssh boxy-1` works from anything that speaks SSH, including
Claude Code's remote workflows, `scp`, `rsync`, and VS Code Remote-SSH. Each
entry pins `IdentityFile`, `IdentitiesOnly yes`, a per-instance
`UserKnownHostsFile`, and `StrictHostKeyChecking yes`.

The image also ships Claude Code itself (`INSTALL_CLAUDE_CODE=1`), so you can
work from *inside* the box against the mounted volume when that suits better.

---

## Container privileges

Two knobs, both aimed at the VPS rather than your laptop.

### `--caps minimal` (the default)

Drops the four capabilities nothing in a dev box legitimately needs — `MKNOD`,
`SETPCAP`, `SETFCAP`, `FSETID` — keeping the other ten.

The ones it keeps are kept **deliberately**, because losing them produces
confusing failures rather than honest ones. The sharpest example:

```
$ ping -c1 127.0.0.1
exec /usr/bin/ping: operation not permitted
```

`/usr/bin/ping` carries the file capability `cap_net_raw=ep`. The `e`
(effective) bit means that if `NET_RAW` is outside the bounding set, `exec`
of the binary **fails outright** — you don't get a degraded ping, you get a
binary that won't start, with an error pointing nowhere near capabilities.
`KILL` (without it `sudo pkill` fails), `NET_BIND_SERVICE` and `AUDIT_WRITE`
are kept for the same reason.

If something ever fails in a way that smells like a missing privilege:

```bash
boxy create --caps default          # Docker's full 14
```

That's the fastest way to confirm or rule out capabilities as the cause. You
can also add a single capability via `BOXY_MINIMAL_CAPS` instead of abandoning
the reduced set.

---

## Configuration

`~/.config/boxy/config`, sourced as bash. See `boxy.conf.example` for the full
annotated set. Precedence: defaults → config file → `BOXY_*` environment →
flags.

Most-used knobs:

| Variable | Default | |
| --- | --- | --- |
| `BOXY_SSH_KEY` | `<state>/boxy_ed25519` | keypair authorized on every box |
| `BOXY_USER` | `boxyboy` | login user |
| `BOXY_PORTS` | `2718 8888 8000 8080 3000 5000 6006` | what `boxy forward` tunnels |
| `BOXY_BIND_ADDR` | `127.0.0.1` | interface for published ports |
| `BOXY_NET` | `full` | default egress policy |

---

## What's in the image

Debian bookworm, Miniforge (conda-forge channels — no Anaconda ToS
entanglement), Python 3.12. **2.3 GB.**

Default build — the stack you actually work in:

`numpy` · `scipy` · `pandas` · `matplotlib-base` · `jax[cpu]` · `marimo` ·
`ipython` · `uv` · `mamba`/`conda` · `nodejs` · `git` · `git-lfs` · `tmux` ·
`ripgrep` · `fd` · `jq` · `htop` · `build-essential`

Opt-in, because they are large and not everyone wants them in every box:

```bash
boxy build --extras   # jupyterlab polars pyarrow scikit-learn   (+462 MB)
boxy build --claude   # @anthropic-ai/claude-code                (+291 MB)
boxy build --full     # both
```

Nothing here is a one-way door: the conda prefix is owned by the box user, so
`pip install` / `uv pip install` / `mamba install` all work at runtime without
`sudo`.

Two notes on what is deliberately *absent*:

- **`matplotlib-base`, not `matplotlib`.** conda-forge's `matplotlib`
  metapackage pulls the whole Qt6 GUI toolkit — including static `.a`
  libraries — into a headless container reached over SSH. `matplotlib-base` is
  the same plotting library without the interactive backends; `Agg` still
  works, so `savefig()` and marimo/notebook rendering are unaffected. This
  alone was several hundred MB.
- **mamba stays.** All of conda + mamba + rattler + libmambapy is 48 MB, and
  modern conda uses libmamba as its solver anyway, so dropping it would slow
  installs to save ~2% of the image.

Builds for `linux/amd64` and `linux/arm64` from the same Dockerfile. JAX is
CPU-only; for GPU you would add a CUDA build target and `jax[cuda12]`.

---

## Security notes

- SSH is key-only. Passwords exist for `sudo` and are never accepted by sshd.
- Published ports bind to loopback by default.
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
  be the obvious thing to attack — but traffic only flows host → sidecar →
  box, so its listeners bind to its outward address and the private side is
  bare. Verified from inside a box: every port closed by IP and by name, and
  no egress even when given a default route pointing at it. It holds no
  capabilities (`--cap-drop=ALL`) and has `ip_forward=0`, so it cannot be
  turned into a router.
- Boxes cannot reach each other: each isolated box gets its own subnet with no
  route between them.
- **What an isolated box cannot do:** reach the internet, reach the host, or
  reach another box.
- **What it can do:** anything it likes with what you handed it. That is not a
  gap in the implementation, it is the shape of the tool. Concretely:
  - Your `-d` directory is mounted read-write. Code in the box can read,
    modify or encrypt it.
  - A worktree box has your repository's git dir mounted read-write. Code in
    the box can rewrite branches and delete objects in your real repo. It has
    no credentials, so it cannot reach a remote — the blast radius is local.
  - Under `--net limited`, the allowlist constrains *where* you can talk, not
    *what* you can say. A `POST` from inside a limited box reaches
    `api.github.com` and gets a real response. Any allowlisted host that
    accepts uploads is a data path out.
- **The kernel is shared**, so a kernel privilege-escalation bug escapes
  everything above at once — namespaces, cgroups, seccomp and capabilities are
  all enforced by the thing that just got compromised. On Docker Desktop this
  matters less than it sounds: containers run against the VM's kernel, so an
  escape lands in a disposable Linux VM, not on macOS.
- Capabilities are reduced by default (`BOXY_CAPS=minimal`, 10 of Docker's 14)
  but tuned for usability over provable minimality — see the config file for
  which are kept and why.
- **Nothing has to be reapplied.** Isolation belongs to the network, not to
  the running container, so a restart — by you, by the daemon, or by anything
  else — cannot lose it. An earlier design removed the default route at
  runtime and *did* silently un-isolate a box on restart; that class of bug no
  longer exists. `BOXY_RESTART` still defaults to `no`, now purely so a box
  you forgot to remove does not come back on its own.
- No git credentials ever enter a box. A worktree box shares your repository's
  object store, so it can commit; it holds no key and can push nowhere.
- `--net none` and `--net limited` hold up against the box user: the network
  is internal and `CAP_NET_ADMIN` is never granted. What they do not defend
  against is a container escape. Treat them as a strong guardrail — good
  enough to stop a dependency phoning home — rather than a sandbox for
  hostile code.
- There is no startup window. The old design had one — a gap between the
  container starting and the route being deleted, papered over with a
  host-set marker the entrypoint had to wait on. An internal network is in
  force before the container's first instruction runs, so both the gap and
  the handshake are gone.

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
