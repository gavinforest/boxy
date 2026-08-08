# boxy

Transparent, SSH-reachable development containers with a Docker backend. Each box is
a Debian container with a preinstalled Python stack, a non-root user, a
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
./boxy build          # boxy-base:latest + the egress sidecar (~7 min, 2.25 GB)
./boxy config --init  # writes ~/.config/boxy/config and the egress allowlist
./boxy create .       # mount the current directory at /work
./boxy ls
./boxy ssh boxy-1
```

Put `boxy` on your `PATH`. A symlink is fine: boxy follows the link back to
the real file before deciding where its own `Dockerfile`, `docker/` and
`boxy.conf.example` live, so `boxy build` and `boxy config --init` read them
from the repository rather than from wherever the link happens to sit.

```bash
ln -s "$PWD/boxy" /usr/local/bin/boxy
```

See [TOUR.md](TOUR.md) for a more detailed walkthrough.

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

**Container host keys are persisted and pinned.**
`<state>/instances/<name>/hostkeys` is bind-mounted into the container. The box
generates its SSH host keys there on first start — the keys it identifies itself
with — and because that directory is a bind mount, boxy reads the public key
straight off the host filesystem and writes a real `known_hosts` entry before it
ever connects. So the first connection is already verified: no
trust-on-first-use prompt, and no `StrictHostKeyChecking=no`.

---

## Commands

**boxy commands** —

| Command                       | What it does                                          |
| ----------------------------- | ----------------------------------------------------- |
| `boxy create [options]`       | Create and start a box (see below)                    |
| `boxy ssh [NAME] [-- CMD]`    | Interactive session, or one command with `--`         |
| `boxy forward [NAME] [PORTS]` | Tunnel box ports to the _same_ localhost numbers; `--bg` / `--stop` to run it in the background |
| `boxy rm NAME...`             | Remove a box; never touches your files                |
| `boxy ls`                     | List boxes with status, SSH port, net mode, workdir   |
| `boxy images [-v]`            | Build variants, which are built, and what runs on them |
| `boxy info [NAME]`            | One box in detail, config and actual state            |
| `boxy password [NAME]`        | Print the stored sudo password                        |
| `boxy env [NAME] [K=V]`       | Set/inject or list environment variables the box sees |
| `boxy allow [NAME] [DOMAIN]`  | Widen a running `--net limited` box's egress, no restart |
| `boxy ssh-config [--install]` | Emit / install an `ssh_config` covering every box     |
| `boxy build [--full]`         | Build the images                                      |
| `boxy doctor [--verbose]`     | Check the local setup; `-v` adds `boxy info` per box  |
| `boxy config [--init [FROM]]` | Show the effective config, or install one             |

**Docker passthroughs** — thin wrappers that resolve the box name, add boxy's
defaults, and hand off to Docker. Added for convenience of use. If you prefer, run the bracketed command yourself; the
container name is the box name.

| Command                     | Wraps               | Why bother                                                                                                      |
| --------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `boxy exec [NAME] [-- CMD]` | `docker exec`       | Sets the box user, `$HOME` and `/work`; works when SSH is broken. Needs a terminal only for the no-command form |
| `boxy logs [NAME] [-f]`     | `docker logs`       | The entrypoint's setup narration — the first place to look when a box misbehaves. `--sidecar` reads the sidecar's instead; control characters are stripped unless `--raw` |
| `boxy start\|stop\|restart` | `docker start/stop` | Moves the sidecar with the box, and waits for SSH to answer before returning                                     |
| `boxy top [--watch]`        | `docker stats`      | Filters to boxy-managed containers                                                                              |

The name may be omitted whenever exactly one box exists. Proxy sidecars don't
count toward that — a single `--net limited` box still lets you omit it. That
holds for the passthroughs too: a leading `-f` or `--tail` is read as docker's
flag rather than as a box name, and `boxy exec -- CMD` separates a command
from a name you left out, exactly as `boxy ssh -- CMD` does.

`boxy logs` is a passthrough with one deliberate exception: control characters
are stripped from its output. A container chooses what goes into its own log —
tinyproxy echoes the requested domain into a denial line, sshd echoes the
username of a failed login — so raw `ESC` bytes in that text would let a box
drive your cursor and paint over lines already on screen. It cannot forge a log
*line* (a bare CR truncates, and `%0d%0a` is never decoded), so what's stored is
honest either way; this is only about what a terminal is asked to render.

The filtering is not conditional on writing to a terminal, because
`boxy logs -s web | grep refused` renders at the *end* of the pipeline and boxy
can't see that far. `ESC` alone is removed, so an injected `[2A` stays in the
output as visible text rather than disappearing. Use `boxy logs --raw` (or
`docker logs` directly) when you want the container's exact bytes.

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

**A create that fails cleans up after itself.** Everything up to port planning
only reads; past that, a failure can have already made a git worktree and its
branch, a scratch directory, and a state directory holding the sudo password.
All of it is undone, and boxy says so:

```
$ boxy create worktree -n web --net limited
adding worktree boxy/web to /Users/you/code/thing
Error response from daemon: all predefined address pools have been fully subnetted
warning: create failed; undoing what it had already made
  removed the worktree and branch boxy/web
```

The one thing it will not undo is work: the worktree is retired with plain
`git worktree remove`, which refuses on uncommitted changes, and the branch is
deleted only while it still points at the commit it was created from. A
directory you named with a path target is never touched — boxy did not make it.

That particular error is worth knowing about, because it is the failure you are
most likely to meet: each `--net none` or `--net limited` box gets its own
Docker network, and Docker's default address pools run out somewhere around
**two to three dozen** of them. `docker network prune` reclaims any that
outlived their boxes.

```
-b, --ref REF         commit-ish the worktree branches from (default: HEAD)
-n, --name NAME       instance name (default: boxy-N)
    --password PASS   sudo password (default: random EFF passphrase)
-u, --user NAME       login user (default: boxyboy)
-k, --key PATH        public key to authorize (default: $BOXY_SSH_KEY.pub)
    --net MODE        full | none | limited   (default: full)
    --caps MODE       minimal | docker-default        (default: minimal)
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
- **`-e` does not reach `boxy ssh`.** A variable set with `-e` lands in PID 1's
  environment, which the box's own processes and `boxy exec` inherit. An ssh
  session does not: sshd builds a fresh environment through PAM rather than
  inheriting PID 1's. Use `boxy env` below, which reaches every way in — and
  unlike `-e`, works on a box that is already running, so you do not have to
  recreate the box to add a variable.

---

## Environment variables

```bash
boxy env boxy-1 API_KEY=secret REGION=us-east-1   # set
boxy env boxy-1                                   # list
boxy env boxy-1 --unset REGION                    # remove
```

Sets environment variables within the box. Visible to `ssh box cmd`, an interactive `ssh box`, and `boxy exec` alike, and
they survive `boxy stop` / `boxy start`. Listing works on a stopped box too —
the variables live in the container's filesystem, so boxy reads them out with
`docker cp` rather than needing anything running to ask.

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
variables die with the child, so `bash /etc/profile.d/boxy-env.sh` would
accomplish nothing at all. `.` means "here", not "over there".

`. ~/.bashrc` also works, and is easier to remember — boxy's block at the top of
it sources the same loader. The catch is that it runs the rest of that block
too, including the `cd /work`, so it will move you out of whatever directory you
were in. Source the loader directly if that matters.

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

`boxy rm` deletes the container and boxy's per-instance bookkeeping — its host
key, `known_hosts`, and password file. Your files are either in the named
directory given to `boxy create` (or volumes you mounted yourself), or sitting in
the temp area.

**A scratch workdir is printed once, at `rm`, and then boxy forgets it.** The
path lived in a label on the container, so removing the container is what loses
it — there is no later command that will tell you where a removed box's scratch
directory was. Copy the path out of the `rm` output if you might want it, or
create with a named directory when the files matter.

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

**Only committed content crosses over.** A worktree is a checkout of a commit,
not a copy of your working directory, so the box gets exactly what is in `HEAD`
and nothing else. Staying behind on the host:

- edits to tracked files you have not committed — the box sees the committed
  version, not yours
- files that are staged but not committed
- untracked files, including ones you just have not `git add`ed yet
- everything `.gitignore` matches: `.venv/`, `node_modules/`, `data/`, build
  outputs

This is the most common first-run surprise, and a quiet `git status` does not
rule it out, because ignored files never appear there. If a box comes up
looking half-empty, the count is the fast check:

```bash
$ git status --short          # uncommitted and untracked
$ git ls-files | wc -l        # how many files a worktree box will actually get
```

Submodules are empty in a new worktree too — `git worktree add` does not
populate them.

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

The branch always survives `boxy rm` (because of the shared object store); it may hold the only copy of the work.
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
> docker network instead of the container, so network state does not depend on
> anything the box controls, and cannot be spoofed from inside it.

## Controlling internet access

```bash
boxy create --net full      # default: ordinary bridge, unrestricted, no sidecar
boxy create --net none      # sealed: internal network, nothing in or out to host except through a sidecar
boxy create --net limited   # sealed + an allowlisting proxy sidecar
```

Both restricted modes put the box on a `docker network create
--internal` network. Docker is responsible for enforcing
the isolation: no default route is installed, no NAT rule exists for the subnet, and
external DNS resolution is dead. Nothing about the isolation lives in the image
or in the running container — it is entirely a property of the network the box
is attached to, so there is no state to lose: isolation survives a restart, a
daemon restart, or anything else that happens without boxy's involvement.

Root inside the box cannot undo configuration, because `CAP_NET_ADMIN` is never granted:

```
$ sudo ip link add dummy0 type dummy
RTNETLINK answers: Operation not permitted
```

### The sidecar

Internal networks come with one Docker limitation: **Docker will not create a
host port binding for a container whose only network is internal.** `-p` is
accepted and silently discarded — no error, and `docker port` reports nothing.
So a sealed box publishes nothing itself. Instead each one gets a sidecar,
attached to two networks: the box's internal network, and `boxy-egress`, a
shared ordinary (non-internal) bridge where only sidecars live. Being on both is
what lets it carry traffic in either direction:

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
by name — and an intact sidecar cannot be used as a router even when handed an
explicit default route pointing at it. It runs with `--cap-drop=ALL` and
`net.ipv4.ip_forward=0`. (What "intact" is doing there is spelled out below.)

An ingress-only sidecar (`--net none`) keeps nothing at all; a proxying one
(`--net limited`) gets exactly four back. `SETUID`, `SETGID` and `SETPCAP` are
tinyproxy's own privilege drop to its unprivileged user, and `KILL` belongs to
the supervisor — it has to stop tinyproxy to reload the allowlist, and by then
tinyproxy is no longer running as root.

Under `--net limited` the box _does_ reach the proxy port, necessarily, and it is the one listener exposed to the box.

### The sidecar is a trust boundary

Be clear about what the sidecar's hardening does and does not buy, because the
sidecar is the one component that is deliberately on both sides.

**It has full internet access, by design.** It sits on `boxy-egress`, an
ordinary bridge, with a default route and working DNS. That is the entire reason
it exists.

**So a compromised sidecar defeats the isolation completely.** `--cap-drop=ALL`
and `ip_forward=0` do not prevent this. They stop privilege escalation and
_kernel_ routing; relaying a TCP connection in userspace needs neither. And the
sidecar image ships `socat` and `tinyproxy` already, because ingress and the
allowlist need them. Demonstrated on a `--net none` box by starting one extra
`socat` listener inside its sidecar:

```
box → sidecar:9999 → 1.1.1.1   403     ← a real HTTP response
box → 1.1.1.1 (direct)         000     ← same box, same moment
```

**What actually protects a sealed box is reachability, not hardening.** Under
`--net none` the box has no way to talk to the sidecar at all — every port
closed, nothing listening on the private side — so there is no path from box to
sidecar to attack in the first place. `ip_forward=0` and the dropped
capabilities are defence in depth behind that, not the thing doing the work.

**Under `--net limited` the surface is real**, because the box must reach
tinyproxy for the mode to function. tinyproxy is then the boundary between a box
and unrestricted egress, and it is ordinary C software parsing input the box
controls. This is a meaningful difference between the two modes: `--net none`
gives the box nothing to attack, `--net limited` gives it one thing.

The entrypoint exports `HTTP_PROXY`/`HTTPS_PROXY` (into `/etc/environment`, so
even non-interactive SSH commands see them), points `git`'s HTTP transport at
the proxy, and installs a `ProxyCommand` so `git@github.com` still works over
a CONNECT tunnel.

```bash
boxy create worktree --net limited --allow example.com
boxy logs --sidecar boxy-1          # every denial is logged here
#   NOTICE  Proxying refused on filtered domain "example.com"
```

`--sidecar` (`-s`) is the thing to reach for whenever a request fails and the
box itself has nothing to say about it: the box only sees a CONNECT that did
not work, and the reason lives on the other container. It takes docker's own
options too, so `boxy logs -s boxy-1 -f` follows the denials live. The
underlying container is always `boxy-sidecar-` plus the box name, if you would
rather talk to docker directly.

That log is deliberately exception-only on the ingress side. The full
per-connection record — who connected, when, whether the box answered — is
kept separately and read with `--verbose` (`-v`):

```bash
boxy logs -v boxy-1               # every connection through the relay
boxy logs -v boxy-1 -f            # follow it live
#   socat[110] N accepting connection from AF=2 172.19.0.1:44802
#   socat[110] N opening connection to AF=2 172.19.0.3:22
```

The split exists because socat at `-dd` spends about a dozen lines on one
connection, which would bury everything else. Error-level lines are echoed
back into the container log so `boxy logs -s` still shows real faults on its
own; warnings are not, because "connection reset by peer" fires on every
ordinary close and would let anyone reaching a published port flood it.

The trail lives inside the sidecar and is read with `docker cp`, so it is
still available after that sidecar has stopped — which is when a dead relay
most needs explaining. It goes away with the container on `boxy rm`, like any
docker log.

The shipped allowlist covers PyPI, conda-forge, GitHub, npm, Debian, Hugging
Face and the Anthropic API.

**Entries are domains, not patterns.** The sidecar compiles the list into POSIX
extended regexes and escapes only dots, so anything else with meaning in a regex
would survive into the pattern and widen the policy silently — `[^q]*` becomes
`^(.*\.)?[^q]*$`, which matches every domain there is. Every way into the list
is checked against the same rule: `--allow`, `boxy allow`, and the file itself.

```
$ boxy create --net limited --allow '*.example.com'
error: --allow: '*.example.com' — drop the '*.', subdomains are already included

$ boxy allow web 'not a domain'
error: allow: 'not a domain' is not a domain. Entries become regexes in the
       proxy's filter, so only letters, digits, hyphens and dots are accepted
```

Subdomains are always included, which is why there is no wildcard syntax to
get wrong: `github.com` already covers `api.github.com`.

**The shared allowlist is read once, at `boxy create`**, and copied to a file of
the box's own:

```
~/.local/share/boxy/instances/<name>/proxy/allowlist.txt
```

That copy — not the shared file — is what the box actually enforces. Editing
`~/.config/boxy/allowlist.txt` therefore affects the *next* box you create and
never rewrites the rules under boxes already running.

To change what a running box may reach, use `boxy allow`:

```bash
boxy allow web example.com        # widen this box, now
boxy allow web                    # print what it may currently reach
boxy allow web --reload           # replace from ~/.config/boxy/allowlist.txt
```

It takes effect in about three quarters of a second, and **live ssh sessions and
port forwards are not disturbed** — which is the whole difficulty, since an isolated
box's ssh port is carried by socat inside that same sidecar and restarting the
container drops every session it is holding. `boxy allow` never writes to
`~/.config/boxy/allowlist.txt`; a grant applies to that one box until you
`boxy rm` it. It only works on `--net limited`, the only mode with an allowlist
to widen.

<details>
<summary>How the reload works, and why it isn't simply a restart</summary>

The box's copy is bind-mounted into the sidecar **read only** at
`/etc/boxy-proxy/allowlist.txt`. Two consequences follow. Changing policy is a
host-side write plus one signal, so nothing is exec'd into the sidecar to move
it; and the sidecar cannot edit its own rules, so a compromised one has no way
to make a widening of its policy persist.

tinyproxy compiles its filter list once at startup. It does have a `SIGHUP`
handler, but that only re-reads the config file — signal it directly and it
will cheerfully log `Reloading config file finished` while continuing to
enforce the old policy. Restarting the process is the only thing that actually
reloads it.

So the sidecar's PID 1 is the entrypoint script acting as a supervisor, rather
than tinyproxy itself: on `SIGHUP` it rebuilds the filter and restarts *only*
tinyproxy, leaving the socat listeners — and the ssh sessions riding them —
untouched. It bumps a counter at `/run/boxy-proxy-generation` each time, which
`boxy allow` reads before and after signalling, so the restart is confirmed
rather than assumed.

The counter alone is not enough, though, and the reason is worth knowing if you
ever build something similar. A bind-mounted write is **not instantly visible
inside the container** on Docker Desktop, where the mount crosses a virtual
filesystem into the VM rather than being the same kernel's page cache —
measured here as usually visible on the first read, occasionally not for the
better part of a second. Signalling immediately therefore let the supervisor
rebuild the filter from the *old* file, bump its generation, and report a
perfectly healthy reload of a policy nobody asked for. The counter could not
catch that: it confirms a restart happened, not that the restart read what you
wrote. So `boxy allow` waits until the sidecar can see the exact policy it
just wrote, and only then signals.

Two consequences of the sidecar's PID 1 being a shell are worth naming. It
needs `CAP_KILL`, because tinyproxy drops to its own user and signalling
another user's process is exactly what that capability governs — without it the
reload fails with `EPERM`. And it must trap `SIGTERM` itself, because the
kernel discards default-action signals sent to PID 1: an untrapped shell there
never hears `docker stop` and waits out the full ten-second grace period before
being killed.
</details>

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

`boxy` regenerates a standalone `ssh_config` on every create/remove. It is one
file covering **every** box at once — one `Host` block per box, sidecars
excluded — not a per-box file, so a single `Include` stays correct as you add
and remove boxes:

```bash
boxy ssh-config              # print it
boxy ssh-config --install    # Include it from ~/.ssh/config
```

After `--install`, `ssh boxy-1` works from anything that speaks SSH, including
Claude Code's remote workflows, `scp`, `rsync`, and VS Code Remote-SSH. Each
entry pins `IdentityFile`, `IdentitiesOnly yes`, a per-instance
`UserKnownHostsFile`, and `StrictHostKeyChecking yes`.

Claude Code can also run _inside_ the box, against the mounted volume, when that
suits better — it is not in the default image, so build it in with `boxy build
--claude` (or `--full`).

---

## Container privileges

Two knobs controlling how much the box's root user can do.

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
boxy create --caps docker-default   # Docker's full 14
```

Note which is which: **`minimal` is boxy's default; `docker-default` means
Docker's own set.** The value was originally spelled `default`, which read
backwards — it named the set you never got by default. That spelling is now
rejected rather than quietly accepted: the two readings differ by ten
capabilities, so anyone writing `default` to mean "whatever boxy does normally"
is told they asked for the opposite instead of being handed it.

That's the fastest way to confirm or rule out capabilities as the cause. To
grant one specific capability without abandoning the reduced set, add it to
`BOXY_MINIMAL_CAPS` — a config variable, not a code change. Set it in
`~/.config/boxy/config` (or export it before running boxy) with the full list
you want:

```bash
BOXY_MINIMAL_CAPS="CHOWN DAC_OVERRIDE FOWNER KILL SETGID SETUID SYS_CHROOT NET_BIND_SERVICE NET_RAW AUDIT_WRITE SYS_PTRACE"
```

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
| `BOXY_PORTS`     | `2718 8888 8000 8080 3000 5000 6006` | what `boxy forward` tunnels when you name no ports |
| `BOXY_BIND_ADDR` | `127.0.0.1`                          | interface for published ports                   |
| `BOXY_NET`       | `full`                               | default egress policy                           |

### Installing a config

```bash
boxy config                            # show the effective configuration
boxy config --init                     # install the bundled example
boxy config --init ~/team/boxy.conf    # install that file instead
```

`--init` takes the file to install **from**; it always writes to the path boxy
actually reads, so an imported config is in effect immediately. That is the
point of the argument being a source rather than a destination — a config
written somewhere boxy does not look would need a second step to matter.

It never overwrites an existing config: move the old one aside first.

`--init` never overwrites. If a config or an allowlist is already there it
writes nothing and names both, because deciding what to do with them is yours:

```
$ boxy config --init
warning: ~/.config/boxy/config already exists
warning: ~/.config/boxy/allowlist.txt already exists
boxy will not overwrite either; remove or move them, then re-run
error: config: nothing written
```

### Putting the config somewhere else

`BOXY_CONFIG_DIR` is the one knob, and it moves everything:

| Variable          | Default          | |
| ----------------- | ---------------- | --- |
| `BOXY_CONFIG_DIR` | `~/.config/boxy` | holds `config` and `allowlist.txt` |

```bash
BOXY_CONFIG_DIR=~/work/boxy boxy config --init ~/team/boxy.conf
BOXY_CONFIG_DIR=~/work/boxy boxy create .
```

That is how you keep more than one setup around. There is deliberately **no
separate variable for the config file**: two knobs would let the pair come
apart, with the config read from one directory and the allowlist from another,
and nothing to tell you it had happened.

**It can only come from the environment.** It names the directory holding the
file that configures boxy, so a value read *from* that file could never have
applied to finding it — by then boxy has already read it. Setting
`BOXY_CONFIG_DIR` inside your config is therefore circular, and boxy says so
and ignores it rather than letting it half-apply:

```
$ boxy config
warning: ignoring BOXY_CONFIG_DIR set inside ~/.config/boxy/config —
         it selects that file, so it must come from the environment
```

The rest of that config still loads normally; only the one line is dropped.

---

## What's in the image

Debian bookworm, Miniforge, Python 3.12. **2.25 GB.**

Miniforge rather than Miniconda because it defaults to the community-run
**conda-forge** channel. Anaconda's own `defaults` channel is covered by
commercial terms of service that require a paid licence for organisations over a
certain size — conda-forge carries no such condition, so an image built this way
raises no licensing question wherever it ends up.

The default build, by where each package comes from:

| Source | Packages |
| --- | --- |
| apt | `git` · `git-lfs` · `zsh` · `tmux` · `htop` · `jq` · `ripgrep` · `fd-find` · `rsync` · `build-essential` · `openssh-server` · `sudo` |
| conda-forge | `python` · `numpy` · `scipy` · `pandas` · `matplotlib-base` · `ipython` · `nodejs` |
| pip | `jax[cpu]` · `marimo` · `tqdm` · `rich` · `httpx` · `uv` . `gomp`|
| bundled | `conda` / `mamba` (from the Miniforge installer) |

`fd-find` installs its binary as **`fdfind`** on Debian, not `fd`.

### The shell

The box user's login shell is **zsh**, so `boxy ssh` lands in it, with the
`crunch` prompt — box name, conda env, time, working directory, git branch and
a clean/dirty mark:

```
web: (base) {14:22} /work:boxy/web ✓ $
```

The **box name comes first**, in magenta, because a prompt that looks like a
host prompt is how you end up running something in the wrong place — and with
two boxes open in adjacent tabs it is the only thing that tells them apart. It
comes from `$BOXY_NAME`, which reaches the shell through `sshd`'s pam_env.

conda's own `changeps1` is switched off in the image and the `(base)` marker is
rendered by `docker/zshrc` from `$CONDA_DEFAULT_ENV`. Otherwise conda would
prepend it at activation — which happens after `.zshrc` runs — and would always
take the leftmost slot ahead of the box name. It still tracks
`conda activate` live.

There is no oh-my-zsh. The theme needs three things from it — a colour table,
`git_prompt_info` and `ruby_prompt_info` — and `docker/zshrc` defines them in a
dozen lines instead of carrying a framework clone in the image. That also fixes
a real failure: oh-my-zsh's `git_prompt_info` is asynchronous, filled in by a
`precmd` worker through `zle -F`, and in a box driven over SSH by a script that
worker frequently never delivers, so the branch simply never appears. The
version here is synchronous. The theme file itself is unmodified, so it stays
interchangeable with the same theme on a normal oh-my-zsh machine.

Bash is still installed and still fully configured, and **`boxy exec` uses
`bash -l` deliberately** — a broken zsh startup file cannot lock you out.

One wrinkle matters if you edit the image. Debian's `/etc/zsh/zprofile` is
comments only; it never sources `/etc/profile`, so a zsh login shell sees
nothing in `/etc/profile.d`. `PATH` and the proxy arrive regardless, because
`sshd`'s pam_env reads `/etc/environment` — but `cd /work` and the `boxy env`
loader would not. The entrypoint writes those into `~/.zshenv`, which zsh reads
on *every* invocation, so one file covers both an interactive `ssh box` and a
non-interactive `ssh box cmd`. Bash needs two files for the same job.

### Build variants

Two additions are opt-in, because they are large and not everyone wants them in
every box:

```bash
boxy build --extras   # jupyterlab polars pyarrow scikit-learn   (+462 MB)
boxy build --claude   # @anthropic-ai/claude-code                (+291 MB)
boxy build --full     # both
```

**Every image is named for what is in it.** There is no `boxy:latest`, and
nothing moves:

| Build | Image |
| --- | --- |
| `boxy build` | `boxy-base:latest` |
| `boxy build --extras` | `boxy-extras:latest` |
| `boxy build --claude` | `boxy-claude:latest` |
| `boxy build --full` | `boxy-full:latest` |

All four can sit side by side, and the build tells you how to use what it just
made:

```
✓ built boxy-full:latest (2.72 GB), boxy-internalproxy:latest

  boxy create . --image boxy-full:latest
```

`boxy create` uses **`boxy-base:latest`** unless you pass `--image` or set
`BOXY_IMAGE`. That is the whole rule — a name always means one stack, so there
is never a question of what you are about to run. The cost is that building a
variant does not silently become your default; you say which one you want, once,
and `boxy images` shows the whole picture:

```
$ boxy images

VARIANT         IMAGE                      SIZE     BUILT              IN USE
base (default)  boxy-base:latest           2.25GB   About an hour ago  2 boxes, 2 running
extras          boxy-extras:latest         -        not built          none
claude          boxy-claude:latest         2.54GB   About an hour ago  1 box, 0 running
full            boxy-full:latest           -        not built          none

sidecar         boxy-internalproxy:latest  115MB    About an hour ago  1 (boxy managed)
```

Every variant appears whether or not you have built it, because "have I built
the full one?" is not a question a list of what exists can answer. The sidecar
is counted too — that number is worth knowing — but sits apart and carries no
running split, because a sidecar is up exactly when its box is. Its count needs
no noun either, the row having already said `sidecar`, which leaves
`(boxy managed)` against the number it qualifies. `IN USE` counts rather than naming — a bare `2` in that column would read as
`boxy-2`, and a name list has no bounded width — so `boxy images -v` names them,
and `boxy info` reports the image from the other end, per box.

Each image also carries a `boxy.variant` label, which is what identifies it if
you retag it or set `BOXY_IMAGE` to a name of your own.

Building a second variant does not rebuild the first. The `INSTALL_*` args are
declared immediately above the `RUN` that reads them rather than at the top of
the Dockerfile, because an `ARG` in scope contributes to every later layer's
cache key whether or not that layer uses it — declared at the top, `--claude`
gave the `apt` layer a key no build had produced and re-downloaded the whole of
Debian before reaching the one `npm` line that differs. As written, all four
variants share every layer up to the point where they genuinely diverge, so the
second one costs only what it adds.

`BOXY_IMAGE` in your config sets which variant a plain `boxy create` gets, and
the build names follow it: `BOXY_IMAGE=myimg:v2` makes `boxy build --full`
produce `myimg-full:v2`. Setting it to `boxy-full:latest` is the ordinary way to
make the fat image your default — and `boxy build --full` still writes
`boxy-full:latest`, not `boxy-full-full:latest`.

Installing into a running box works too, with **no `sudo` needed**: the conda
prefix is owned by the box user. Verified working at runtime: `pip install`,
`uv pip install`, `conda install` and `mamba install` alike.

`uv pip install` is `uv`'s reimplementation of pip's interface — same
`requirements.txt`, same PyPI, same target environment, just much faster. It
manages the same site-packages `pip` does, so the two can be mixed freely.
`conda install` and `mamba install` are the ones to reach for when a package
needs non-Python libraries; `mamba` is the faster solver and modern `conda` uses
it internally anyway, so either is fine.

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

For the full picture — how both containers are built, which process runs as
what, where every log goes, and what does *not* hold up — see
[SECURITY.md](SECURITY.md). The highlights:

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
- **The sidecar is a trust boundary, and under `--net none` the box cannot
  reach it.** It is dual-homed and has real internet access, so it is the
  obvious thing to attack — but traffic only flows host → sidecar → box, its
  listeners bind to its outward address, and the private side is bare. Verified
  from inside a box: every port closed by IP and by name, and no egress even
  when handed a default route pointing at it. That unreachability is what
  protects a sealed box. `--cap-drop=ALL` and `ip_forward=0` are defence in
  depth behind it, and are narrower than they look: they stop privilege
  escalation and kernel routing, but **a compromised sidecar could still relay
  the box to the internet in userspace**, which needs no capabilities and no
  forwarding. Under `--net limited` the box must reach tinyproxy for the mode to
  work at all, so there the surface is real.
- Boxes cannot reach each other: each isolated box gets its own subnet with no
  route between them.
- **What an isolated box cannot do:** reach the internet, reach the host, or
  reach another box — assuming its sidecar is intact, per the point above.
- **What it can do:** anything it likes with its working directory (and local git dir), and its allowed network access. Concretely:
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
  else — cannot lose it. `BOXY_RESTART` still defaults to `no`, now purely as a
  lifecycle preference: with any other value Docker would restart the box for
  you after a daemon restart or a reboot, so a box you had finished with would
  reappear — running, and holding its SSH port — without you asking for it.
- `--net none` and `--net limited` hold up against the box user: the network
  is internal and `CAP_NET_ADMIN` is never granted. What they do not defend
  against is a container escape. They're a strong guardrail, and stop dependencies phoning home, but not a sandbox for
  hostile code.
- There is no gap between container startup (completion of entrypoint) and complete configuration.

---

## Troubleshooting

**`boxy doctor`** first — it checks the daemon, images, keys and wordlist
cache, and counts boxes and any orphaned state left by a `docker rm` done
outside boxy. Add `--verbose` for a full `boxy info` on every box.

It does *not* check whether an isolated box is still isolated, and there is
nothing there to check: isolation is a property of the box's network, which
Docker enforces and a restart cannot undo. An earlier boxy applied isolation
to the running container and did need that check.

**Box created but SSH times out.** Read `boxy logs <name>`; the entrypoint
narrates every step. Then `boxy exec <name>`, which uses `docker exec` and
does not depend on SSH at all.

**A `--net limited` box can't reach something it should.** `boxy logs
--sidecar <name>` names every refused domain. `boxy allow <name> <domain>`
grants it to that box straight away, without dropping the session you are sitting
in. For a domain every box should have, add it to `~/.config/boxy/allowlist.txt`
instead — that applies to boxes created afterwards — or pass `--allow` on the next
`create`. Remember that a blocked HTTPS request looks like a timeout/`000`, not a
403.

**An isolated box is unreachable over SSH.** Its ports live on the sidecar,
so check that one first: `boxy logs --sidecar <name>` should report the
listeners it placed, and `boxy logs -v <name>` shows whether your connection
reached it at all. If it exited, the box itself is fine and still reachable
with `boxy exec <name>`.

**Permission errors on a mounted volume (Linux hosts).** boxy passes your
host UID/GID and the entrypoint remaps the box user to match. If you mounted a
tree owned by someone else, that will not help; `chown` it or mount elsewhere.

**`git` in a worktree box says "not a git repository".** The box needs the
shared git dir mounted at the same absolute path the worktree's `.git` file
names. `boxy info NAME` shows the branch and repo; check that the repo still
exists at that path and was not moved after the box was created.
