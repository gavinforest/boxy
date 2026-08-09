# boxy

Transparent, SSH-reachable development containers with a Docker backend. Each
box is a Debian container with a preinstalled Python stack, a non-root user, a
known SSH keypair, a mounted working directory, published ports, and an
optional egress allowlist.

Network access is graded to `full` (unrestricted), `limited` (an HTTP proxy
sidecar enforcing an allowlist), or `none` (sealed, with a sidecar carrying
port forwarding and ssh inward only).

```
$ cd ~/code/experiment && boxy create .
created instance 1 (boxy-1), ssh at port 2200

$ boxy create worktree
created instance 2 (boxy-2), ssh at port 2201
  branch  boxy/boxy-2   (shares history with /Users/you/code/experiment)

$ boxy ssh boxy-2
boxyboy@boxy-2:/work$
```

**Index of the Documentation:**

| | |
| --- | --- |
| **README** (you are here) | what boxy does and how to drive it |
| [TOUR.md](TOUR.md) | what it looks like running, captured against a live Docker daemon |
| [DESIGN.md](DESIGN.md) | why it is built this way, and previous pitfalls |
| [SECURITY.md](SECURITY.md) | security architecture, and what holds up when something is compromised |

---

## Quick start

Start by making sure Docker is installed, then

```bash
./boxy build          # boxy-base:latest + the egress sidecar (~7 min, 2.25 GB)
./boxy config --init  # writes ~/.config/boxy/config and the egress allowlist
./boxy create .       # mount the current directory at /work
./boxy ls             # view all boxy instances
./boxy ssh boxy-1     # ssh into boxy-1 (default first box)
```

To put `boxy` on your `PATH`, use a symlink — boxy follows the link back to the
real file before deciding where its own `Dockerfile`, `docker/` and
`boxy.conf.example` live:

```bash
ln -s "$PWD/boxy" /usr/local/bin/boxy
```

---

## Commands

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
defaults, and hand off to Docker. The container name is the box name, so you
can always run docker directly instead.

| Command                     | Wraps               | Why bother                                                                                                      |
| --------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `boxy exec [NAME] [-- CMD]` | `docker exec`       | Sets the box user, `$HOME` and `/work`; works when SSH is broken |
| `boxy logs [NAME] [-f]`     | `docker logs`       | The entrypoint's setup narration. `--sidecar` reads the sidecar's instead; control characters are stripped unless `--raw` |
| `boxy start\|stop\|restart` | `docker start/stop` | Moves the sidecar with the box, and waits for SSH to answer before returning |
| `boxy top [--watch]`        | `docker stats`      | Filters to boxy-managed containers |

The name may be omitted whenever exactly one box exists; proxy sidecars don't
count toward that. A leading `-f` or `--tail` is read as docker's flag rather
than as a box name, and `boxy exec -- CMD` separates a command from a name you
left out, exactly as `boxy ssh -- CMD` does.

---

## Creating a box

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
    --caps MODE       minimal | docker-default        (default: minimal)
    --allow DOMAIN    extra allowed domain for --net limited (repeatable)
-p, --publish SPEC    publish a port: PORT or HOSTPORT:PORT (repeatable)
    --image IMG       image to run
    --cpus N          CPU limit
    --memory SIZE     memory limit, e.g. 8g
```

A create that fails cleans up after itself, and will not undo *work* — a
worktree with uncommitted changes is left alone.

**Everything after `--` is handed to `docker run` unchanged**, which is why the
list above is short: boxy carries a flag only where it adds something of its
own.

```bash
boxy create . -- -v ~/data:/data --gpus all --shm-size 2g
```

Passthrough flags are appended last, so yours beats boxy's where docker takes
the last value (`--cpus 1 -- --cpus 3` gives you 3), and adds to it where
docker accumulates (`-v`, `-e`, `--cap-add`). Two exceptions: `--network` is
refused, because boxy owns the network; and `-e` does not reach `boxy ssh`
sessions, so use `boxy env` instead.

---

## Your files

```bash
boxy create .              # mount a directory you own
boxy create worktree       # a fresh branch of the repo you are in
boxy create                # fresh scratch dir in $TMPDIR/boxy/
```

Given a path, that directory is mounted at `/work` as-is — never copied, moved
or deleted. Changes are live in both directions, because `/work` *is* that host
directory. Given nothing, boxy makes a scratch directory under
`$TMPDIR/boxy/<name>.XXXXXX` and leaves it for the OS to reap.

`boxy rm` deletes the container, any sidecar and per-box network, and boxy's
per-instance bookkeeping. **Files stored outside `/work` — in `$HOME`, say —
live only in the container's writable layer and will be deleted without a
prompt.** `docker diff boxy-1` lists what a box has changed since the image if
you want to check first.

### Worktree boxes

`boxy create worktree` gives the box a real git worktree on its own branch, cut
from `HEAD` (or `--ref`). Commit inside the box and the commit is in your
repository immediately — same objects, same refs, nothing to push or pull. The
box holds no credentials, so it can push nowhere.

**Only committed content crosses over.** A worktree is a checkout of a commit,
not a copy of your working directory, so uncommitted edits, staged-but-not-
committed files, untracked files, and everything `.gitignore` matches
(`.venv/`, `node_modules/`, build outputs) all stay behind. Submodules are
empty too. This is the most common first-run surprise, and a quiet `git status`
does not rule it out, because ignored files never appear there:

```bash
git status --short          # uncommitted and untracked
git ls-files | wc -l        # how many files a worktree box will actually get
```

`boxy rm` runs `git worktree remove`, which refuses on uncommitted changes, and
the branch always survives — it may hold the only copy of the work. Details in
[DESIGN.md](DESIGN.md#worktree-boxes-share-history-and-nothing-else).

---

## Network access

```bash
boxy create --net full      # default: unrestricted, no sidecar
boxy create --net none      # sealed: ingress via a sidecar only
boxy create --net limited   # sealed + an allowlisting proxy sidecar
```

Both restricted modes put the box on an internal Docker network — no default
route, no NAT, no external DNS — and give it a sidecar to carry SSH and
published ports inward. Docker enforces this, not the container, so it survives
restarts and root inside the box cannot undo it.

### The allowlist

`--net limited` runs tinyproxy in the sidecar, refusing any domain not in
`~/.config/boxy/allowlist.txt`. The shipped list covers PyPI, conda-forge,
GitHub, npm, Debian, Hugging Face and the Anthropic API.

```bash
boxy create worktree --net limited --allow example.com
boxy logs --sidecar boxy-1        # every denial is logged here
```

**Entries are domains, not patterns**, and subdomains are always included —
`github.com` already covers `api.github.com`, so there is no wildcard syntax to
get wrong.

**The shared allowlist is read once, at `boxy create`.** Editing it affects the
*next* box you create, never one already running. To change a running box:

```bash
boxy allow web example.com        # widen this box, now
boxy allow web                    # print what it may currently reach
boxy allow web --reload           # replace from ~/.config/boxy/allowlist.txt
```

That takes under a second and **does not disturb live ssh sessions or port
forwards**, which is harder than it sounds —
[DESIGN.md](DESIGN.md#reloading-the-allowlist-without-dropping-sessions) has
the mechanism. A grant applies to that one box until you `boxy rm` it.

> A *blocked HTTPS* request shows up as `curl` exit 7 / status `000`, not a
> 403 — tinyproxy refuses a `CONNECT` by dropping the tunnel, so there is no
> HTTP response to carry a status. Plain HTTP does return a real 403.

---

## Ports

Only SSH is published automatically. For anything else, two options:

```bash
boxy create -n web -p 8000        # publish at create time, docker semantics
boxy forward web --bg 8000        # tunnel over ssh, any time, same port number
boxy forward web --stop           # end every tunnel for the box
```

`-p` is fixed when the container is made; `boxy forward` works on a box that
already exists, keeps the *same* port number on the host, and works on isolated
boxes too. `--bg` is additive — a second call adds ports rather than replacing
them. With no ports named, `boxy forward` uses `BOXY_PORTS`.

Servers must bind `0.0.0.0` to be reachable through `-p`
(`marimo edit --host 0.0.0.0`). Binding `127.0.0.1` is fine over
`boxy forward`, because that tunnel terminates inside the container.
[TOUR §6](TOUR.md#6-ports) walks through both.

---

## Environment variables

```bash
boxy env boxy-1 API_KEY=secret REGION=us-east-1   # set
boxy env boxy-1                                   # list
boxy env boxy-1 --unset REGION                    # remove
```

Reaches new ssh sessions, one-shot `ssh box cmd`, and `boxy exec` alike, and
survives a restart. Listing works on a stopped box. Values need no quotes.
`PATH` and `BOXY_*` are refused.

A session that was already open keeps the old environment — reload it with
`. /etc/profile.d/boxy-env.sh` (the leading `.` matters; it sources into the
current shell rather than a child).

---

## Using a box as a remote (Claude, VS Code, rsync, …)

`boxy` regenerates one standalone `ssh_config` covering every box on each
create and remove, so a single `Include` stays correct:

```bash
boxy ssh-config              # print it
boxy ssh-config --install    # Include it from ~/.ssh/config
```

After `--install`, `ssh boxy-1` works from anything that speaks SSH. Each entry
pins `IdentityFile`, `IdentitiesOnly yes`, a per-instance `UserKnownHostsFile`
and `StrictHostKeyChecking yes`.

**Some clients read `~/.ssh/known_hosts` rather than the per-box file — Claude
Desktop is one.** Opt in once and boxy keeps those entries current for every
box you create afterwards:

```bash
boxy ssh-config --known-hosts     # opt in
boxy ssh-config --no-known-hosts  # opt back out
```

Claude Code can also run *inside* a box; it is not in the default image, so
build it in with `boxy build --claude`.

---

## Images

Debian bookworm, Miniforge, Python 3.12, zsh. **2.25 GB.**

| Source | Packages |
| --- | --- |
| apt | `git` · `git-lfs` · `zsh` · `tmux` · `htop` · `jq` · `ripgrep` · `fd-find` · `rsync` · `build-essential` · `openssh-server` · `sudo` |
| conda-forge | `python` · `numpy` · `scipy` · `pandas` · `matplotlib-base` · `ipython` · `nodejs` |
| pip | `jax[cpu]` · `marimo` · `tqdm` · `rich` · `httpx` · `uv` · `gomp` |
| bundled | `conda` / `mamba` (from the Miniforge installer) |

**Installing into a running box doesn't require `sudo`** — the conda prefix is owned
by the box user, and `pip`, `uv pip`, `conda` and `mamba` all manage the same
site-packages. `fd-find` installs its binary as `fdfind` on Debian. JAX is
CPU-only. Builds for `linux/amd64` and `linux/arm64`.

Two additions are opt-in, and **every image is named for what is in it** —
there is no `boxy:latest` and nothing moves:

```bash
boxy build            # boxy-base:latest
boxy build --extras   # boxy-extras:latest — jupyterlab polars pyarrow scikit-learn  (+462 MB)
boxy build --claude   # boxy-claude:latest — @anthropic-ai/claude-code               (+291 MB)
boxy build --full     # boxy-full:latest   — both
```

All four sit side by side, and `boxy create` uses `boxy-base:latest` unless you
pass `--image` or set `BOXY_IMAGE` — building a variant does not silently
become your default. `boxy images` lists every variant, built or not. Modifying the base image is a pretty straightforward modification of the Dockerfile. See [DESIGN.md](DESIGN.md#images) for more.

---

## Privileges and passwords

Boxes run with 10 of Docker's 14 capabilities (`--caps minimal`, the default),
dropping `MKNOD`, `SETPCAP`, `SETFCAP` and `FSETID`. If something fails in a
way that smells like a missing privilege, `boxy create --caps docker-default`
restores all 14 and is the fastest way to confirm or rule it out. To keep the
reduced set but add one capability, set `BOXY_MINIMAL_CAPS` in your config. The
set is tuned for honest failures rather than provable minimality —
[DESIGN.md](DESIGN.md#capabilities-are-tuned-for-honest-failures) has the
`ping` example that explains why.

The `sudo` password is four words from the EFF long list (~51.7 bits), stored
host-side at mode 0600; the plaintext never enters the container.

```bash
boxy password boxy-1
# thicken-earlobe-composed-shrunk
```

It gates `sudo` only. **sshd never accepts passwords**, so a box on a public
interface cannot be brute-forced into.

---

## Configuration

`~/.config/boxy/config`, sourced as bash. Precedence, lowest to highest:
defaults → config file → `BOXY_*` environment → flags. See
`boxy.conf.example` for the full annotated set.

| Variable          | Default                              |                                                 |
| ----------------- | ------------------------------------ | ----------------------------------------------- |
| `BOXY_SSH_KEY`    | `<state>/boxy_ed25519`               | keypair authorized on every box                 |
| `BOXY_USER`       | `boxyboy`                            | login user                                      |
| `BOXY_PORTS`      | `2718 8888 8000 8080 3000 5000 6006` | what `boxy forward` tunnels when you name no ports |
| `BOXY_BIND_ADDR`  | `127.0.0.1`                          | interface for published ports                   |
| `BOXY_NET`        | `full`                               | default egress policy                           |
| `BOXY_IMAGE`      | `boxy-base:latest`                   | variant a plain `boxy create` gets              |
| `BOXY_CONFIG_DIR` | `~/.config/boxy`                     | holds `config` and `allowlist.txt`              |

```bash
boxy config                            # show the effective configuration
boxy config --init                     # install the bundled example
boxy config --init ~/team/boxy.conf    # install that file instead
```

`--init` names the file to install **from** and always writes where boxy
actually reads, so an imported config is in effect immediately. It never
overwrites. `BOXY_CONFIG_DIR` moves the config and allowlist together, which is
how you keep more than one setup around; it must come from the environment.

---

## How it works

boxy is one bash script driving `docker`, without requiring any daemon, database, or anything running between you and the container.

- **Docker labels are the state store.** Ports, workdir, network mode and user
  live as `boxy.*` labels on the container itself, so there is nothing to get
  out of sync — `docker rm` a box by hand and boxy stops seeing it.
- **Configuration arrives at runtime**, as environment at `docker run`. One
  image serves every box, so rotating your keypair needs no rebuild and
  `docker history` reveals nothing.
- **Host keys are persisted and pinned**, so the first connection is already
  verified — no trust-on-first-use prompt.
- **Isolation is a property of the Docker network**, not of the container, so
  it cannot be lost on restart or switched off from inside a box.

[DESIGN.md](DESIGN.md) has the full picture, including the parts that were
built differently first.

---

## Security

Full treatment in [SECURITY.md](SECURITY.md). The short version:

- SSH is key-only; published ports bind to loopback by default.
- The box user has `sudo` **inside the container**, and the kernel is shared.
  Container root is not host root, but it is not a hard boundary either.
- No git credentials ever enter a box. A worktree box can commit to your
  shared object store — and rewrite it — but can push nowhere.
- An isolated box cannot reach the internet, the host, or another box. DNS is
  dead in one, closing a covert channel for free.
- Under `--net limited` the allowlist constrains *where* a box can talk, not
  *what* it can say: any allowlisted host that accepts uploads is a data path
  out.
- **These are strong guardrails, not a sandbox for hostile code.**

---

## Troubleshooting

**`boxy doctor`** first — daemon, images, keys, wordlist cache, box count and
any orphaned state. `-v` adds a full `boxy info` per box.

| Symptom | Where to look |
| --- | --- |
| Box created but SSH times out | `boxy logs <name>` — the entrypoint narrates every step, and a failed step leaves the box *running*. `boxy exec <name>` works without SSH |
| A `--net limited` box can't reach something | `boxy logs --sidecar <name>` names every refused domain; `boxy allow <name> <domain>` grants it without dropping your session. Remember a blocked HTTPS request looks like a timeout, not a 403 |
| An isolated box is unreachable over SSH | Its ports live on the sidecar — `boxy logs --sidecar <name>` for the listeners, `boxy logs -v <name>` for whether your connection arrived |
| Permission errors on a mount (Linux) | boxy remaps the box user to your UID/GID; a tree owned by someone else needs `chown` |
| `git` says "not a git repository" | The shared git dir must be at the same absolute path the worktree's `.git` file names. `boxy info NAME` shows the repo; check it was not moved |
| `all predefined address pools have been fully subnetted` | Docker's network limit, not boxy's. `docker network prune`, or raise `default-address-pools` in `daemon.json` |
