# boxy

Disposable, SSH-reachable dev boxes backed by Docker. Each box is a Debian
container with a preinstalled scientific Python stack, a non-root user, a
known SSH keypair, a mounted working directory, published ports, and an
optional egress allowlist.

```
$ boxy create -d ~/code/experiment
created instance 1 (boxy-1), ssh at port 2200

$ boxy create -r git@github.com:you/repo.git
created instance 2 (boxy-2), ssh at port 2201

$ boxy ssh boxy-2
boxyboy@boxy-2:/work$
```

---

## Quick start

```bash
./boxy build          # builds boxy:latest and boxy-proxy:latest (~7 min, 2.3 GB)
./boxy config --init  # writes ~/.config/boxy/config and the egress allowlist
./boxy create -d .    # mount the current directory at /work
./boxy ls
./boxy ssh boxy-1
```

Put `boxy` on your `PATH` (a symlink is fine — it resolves its own directory
to find the `Dockerfile` and `monitoring/` alongside it):

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
   ~/.ssh/id_ed25519 ─────ro mount────────▶  ~boxyboy/.ssh/git_key
   <workdir or $TMPDIR/boxy/…> ──mount────▶  /work
   <state>/hostkeys ──────mount───────────▶  /etc/ssh/hostkeys
   127.0.0.1:2200 ────────publish─────────▶  :22  (sshd, key-only)
   127.0.0.1:<yours> ─────publish─────────▶  only what you pass to -p
```

Three things are worth calling out because they drive most of the design:

**Nothing is baked into the image.** Keys, password hashes, repo URLs, proxy
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
| `boxy info [NAME]` | One box in detail, including its port map |
| `boxy password [NAME]` | Print the stored sudo password |
| `boxy ssh-config [--install]` | Emit / install an `ssh_config` covering every box |
| `boxy build [--full]` | Build the images |
| `boxy doctor` | Check the local setup |
| `boxy config [--init]` | Show or scaffold configuration |

**Docker passthroughs** — thin wrappers that resolve the box name, add boxy's
defaults, and hand off. If you prefer, run the bracketed command yourself; the
container name *is* the box name.

| Command | Wraps | Why bother |
| --- | --- | --- |
| `boxy exec [NAME] [CMD]` | `docker exec` | Sets the box user, `$HOME` and `/work`; works when SSH is broken |
| `boxy logs [NAME] [-f]` | `docker logs` | The entrypoint's setup narration — the first place to look when a box misbehaves |
| `boxy start\|stop\|restart` | `docker start/stop` | Re-applies egress isolation and re-pins the host key on the way back up |
| `boxy top [--watch]` | `docker stats` | Filters to boxy-managed containers |
| `boxy monitor up\|down` | `docker compose` | Points at the bundled monitoring stack |

The name may be omitted whenever exactly one box exists.

### `boxy create`

```
-d, --dir DIR         mount DIR at /work (default: fresh scratch dir in $TMPDIR)
-r, --repo URL        clone URL into /work on first boot
-b, --ref REF         branch/tag to clone
-n, --name NAME       instance name (default: boxy-N)
    --password PASS   sudo password (default: random EFF passphrase)
    --words N         words in the generated passphrase (default: 4)
-u, --user NAME       login user (default: boxyboy)
-k, --key PATH        public key to authorize (default: $BOXY_SSH_KEY.pub)
    --git-key PATH    private key mounted for git (default: ~/.ssh/id_ed25519)
    --no-git-key      withhold git credentials
    --net MODE        full | none | limited   (default: full)
    --allow DOMAIN    extra allowed domain for --net limited (repeatable)
-p, --publish SPEC    publish a port: PORT or HOSTPORT:PORT (repeatable)
-v, --volume SRC:DST  extra bind mount (repeatable)
-e, --env K=V         extra environment variable (repeatable)
    --tailscale       join the tailnet (needs BOXY_TS_AUTHKEY)
    --ts-hostname H   tailnet hostname (default: instance name)
    --image IMG       image to run
    --cpus N          CPU limit
    --memory SIZE     memory limit, e.g. 8g
```

---

## The working directory

```bash
boxy create -d ~/code/thing    # mount a directory you own
boxy create                    # fresh scratch dir in $TMPDIR/boxy/
```

With `-d`, that directory is mounted at `/work` as-is. boxy never creates it,
never moves it, and never deletes it.

Without `-d`, boxy makes a fresh scratch directory under
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

## Ports

**Nothing but SSH is published by default.** Instance *N* gets SSH on
`2200 + N - 1`, and that is the only automatic host binding.

Everything else is one of two explicit mechanisms, both of which state their
mapping rather than making you infer it:

### `boxy forward` — same number on both sides

```bash
boxy forward boxy-1              # tunnels the whole BOXY_PORTS set
boxy forward boxy-1 2718         # just marimo
boxy forward boxy-1 --bg         # background; --stop to end
```

`-L 2718:127.0.0.1:2718`, so a marimo server on `:2718` in the box is on
`:2718` here. Nothing to decode. Only one box can own a given localhost port
at a time, which is the right semantics: forward the box you're working in.
This is the default path and needs no decision at create time.

### `-p` — published, docker-style

```bash
boxy create -p 2718              # localhost:2718 -> container 2718
boxy create -p 12718:2718        # localhost:12718 -> container 2718
```

Exactly docker's `-p` semantics. A bare port means the same number on both
sides; `HOST:CONTAINER` states it explicitly. If the host port is taken you
get an error before anything is created, not a silent remap. `boxy info`
always prints the resulting table.

Use this when you want a binding that outlives a tunnel — a long-running
service, or a box on a VPS reached over tailscale.

> Servers must bind `0.0.0.0` inside the box to be reachable through a
> **published** port — `marimo edit --host 0.0.0.0`, `jupyter lab --ip 0.0.0.0`.
> Binding `127.0.0.1` is fine over `boxy forward`, since the tunnel terminates
> inside the container's own loopback.

Published ports bind to `127.0.0.1` by default (`BOXY_BIND_ADDR`). On a VPS,
leave it that way and reach boxes over tailscale.

---

## Controlling internet access

```bash
boxy create --net full      # default: ordinary bridge, unrestricted
boxy create --net none      # no default route — nothing off the host
boxy create --net limited   # no default route + an allowlisting proxy sidecar
```

Both restricted modes work by **deleting the box's default route** — not by
using `docker network create --internal`. An internal network does block
egress, but it also drops the inbound traffic published ports depend on, which
would leave the box unreachable over SSH and defeat the whole premise. With
only the default route removed, on-link traffic still flows: replies to
published ports reach the host, and a sidecar on the same subnet is still
reachable, while anything needing a gateway goes nowhere.

The route is removed from the *host* via `docker exec --privileged`, which
grants privileges to that one exec'd process. The container itself never holds
`CAP_NET_ADMIN`, so although the box user has `sudo`, restoring the route from
inside fails:

```
$ sudo ip route add default via 172.30.0.1
RTNETLINK answers: Operation not permitted
```

`limited` additionally starts a per-box tinyproxy sidecar attached to both the
box's subnet and a normal bridge, making it the single path out. It refuses
any domain not in `~/.config/boxy/allowlist.txt`.

Isolation is reapplied on every `boxy start`/`restart`, since a restart brings
the default route back.

The entrypoint exports `HTTP_PROXY`/`HTTPS_PROXY` (into `/etc/environment`, so
even non-interactive SSH commands see them), points `git`'s HTTP transport at
the proxy, and installs a `ProxyCommand` so `git@github.com` still works over
a CONNECT tunnel.

```bash
boxy create -r git@github.com:you/repo.git --net limited --allow example.com
docker logs boxy-proxy-boxy-1     # every denial is logged here
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

## Tailscale and a VPS

Pass `--tailscale` and the box joins your tailnet under its own hostname:

```bash
export BOXY_TS_AUTHKEY='tskey-auth-...'   # reusable + ephemeral
boxy create -d ~/code/thing --tailscale
ssh boxyboy@boxy-1                        # via MagicDNS, from anywhere
```

`tailscaled` runs in **userspace-networking** mode, so the box needs no
`/dev/net/tun` and no `NET_ADMIN` capability — it stays an ordinary
unprivileged container. Inbound tailnet connections are proxied to localhost
services, which is enough for sshd on :22.

Use *ephemeral* auth keys: nodes vanish from the tailnet when a box is
destroyed rather than piling up as dead entries.

To drive a remote VPS, point the Docker CLI at it over SSH — boxy needs no
changes, since it only ever talks to `docker`:

```bash
docker context create vps --docker "host=ssh://you@vps.example.com"
docker context use vps
boxy create -r git@github.com:you/repo.git --tailscale --net limited
```

Set `BOXY_SSH_HOST` to the VPS's tailnet name so generated `ssh_config`
entries point somewhere useful, and keep `BOXY_BIND_ADDR=127.0.0.1`.

---

## Monitoring

Two tiers. `boxy top` reads straight from the Docker daemon — no extra
services, no retention — and answers "what is running and what is it using".
The stack below is opt-in and exists for the question `top` cannot answer:
what happened while you were not looking.

```bash
boxy top
boxy top --watch
```

```bash
boxy monitor up      # Grafana → http://localhost:3001  (admin/admin)
boxy monitor status
boxy monitor down
```

cAdvisor reads the cgroup tree, so it discovers every boxy container
automatically — nothing is installed inside a box, which is the point when the
boxes are disposable. node-exporter covers host headroom. The provisioned
"boxy — instances" dashboard shows per-box CPU, memory and network alongside
host CPU/memory/disk.

Both Grafana and Prometheus bind to loopback. On a VPS, reach them over
tailscale and change the Grafana password (`GF_ADMIN_PASSWORD`).

---

## Configuration

`~/.config/boxy/config`, sourced as bash. See `boxy.conf.example` for the full
annotated set. Precedence: defaults → config file → `BOXY_*` environment →
flags.

Most-used knobs:

| Variable | Default | |
| --- | --- | --- |
| `BOXY_SSH_KEY` | `<state>/boxy_ed25519` | keypair authorized on every box |
| `BOXY_GIT_KEY` | `~/.ssh/id_ed25519` | key mounted for git |
| `BOXY_USER` | `boxyboy` | login user |
| `BOXY_PORTS` | `2718 8888 8000 8080 3000 5000 6006` | what `boxy forward` tunnels |
| `BOXY_BIND_ADDR` | `127.0.0.1` | interface for published ports |
| `BOXY_NET` | `full` | default egress policy |
| `BOXY_SSH_HOST` | `127.0.0.1` | host in generated ssh_config |
| `BOXY_TS_AUTHKEY` | *(unset)* | tailscale auth key |

---

## What's in the image

Debian bookworm, Miniforge (conda-forge channels — no Anaconda ToS
entanglement), Python 3.12. **2.3 GB.**

Default build — the stack you actually work in:

`numpy` · `scipy` · `pandas` · `matplotlib-base` · `jax[cpu]` · `marimo` ·
`ipython` · `uv` · `mamba`/`conda` · `nodejs` · `git` · `git-lfs` · `tmux` ·
`ripgrep` · `fd` · `jq` · `htop` · `build-essential` · `tailscale`

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
- `BOXY_GIT_KEY` is mounted read-only and copied to a `0400` file owned by the
  box user. The box user can read it — that is unavoidable if you want to push
  from inside. Use `--no-git-key`, or a dedicated deploy key, when that is not
  a trade you want.
- `--net none` and `--net limited` hold up against the box user: the default
  route is removed from outside and `CAP_NET_ADMIN` is never granted to the
  container, so `sudo ip route add default` inside the box fails. What they do
  not defend against is a container escape, and DNS still resolves through
  Docker's embedded resolver (no data path, but names do leak). Treat them as
  a strong guardrail — good enough to stop a dependency phoning home — rather
  than a sandbox for hostile code.
- There is a sub-second window at `create` between the container starting and
  the route being removed. The entrypoint blocks on a host-set marker before
  cloning, so no repo fetch happens in that window.

---

## Troubleshooting

**`boxy doctor`** first — it checks the daemon, images, keys and wordlist cache.

**Box created but SSH times out.** Read `boxy logs <name>`; the entrypoint
narrates every step. Then `boxy exec <name>`, which uses `docker exec` and
does not depend on SSH at all.

**A `--net limited` box can't reach something it should.** `docker logs
boxy-proxy-<name>` names every refused domain. Add it to
`~/.config/boxy/allowlist.txt` (applies to boxes created afterwards) or pass
`--allow` on the next `create`. Remember that a blocked HTTPS request looks
like a timeout/`000`, not a 403.

**`boxy create` warns that egress is NOT restricted.** The privileged exec
that removes the default route failed. The box is up and usable but has full
internet; `docker exec --privileged <name> ip route del default` reproduces
the failure with a real error message.

**Permission errors on a mounted volume (Linux hosts).** boxy passes your
host UID/GID and the entrypoint remaps the box user to match. If you mounted a
tree owned by someone else, that will not help; `chown` it or mount elsewhere.

**Clone failed.** The box still starts — deliberately, so you can SSH in and
find out why. Check that `BOXY_GIT_KEY` exists and is authorized on the remote.
