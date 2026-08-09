# CLAUDE.md

boxy is a single bash script (`./boxy`, ~3.2k lines) plus a Dockerfile and the
container-side scripts in `docker/`. There is no build step for the CLI itself
and no CI.

- `./boxy` — the whole CLI
- `Dockerfile`, `docker/entrypoint.sh`, `docker/zshrc` — the box image
- `docker/Dockerfile.proxy`, `docker/proxy-entrypoint.sh` — the sidecar image
- `test/{run,core,network,workflow}.sh` — the suites
- [DESIGN.md](DESIGN.md) — why any of the below is true
- [SECURITY.md](SECURITY.md) — the threat model and what is verified by tests

Shell style: bash, `shellcheck`-clean, with `# shellcheck disable=` comments
where a suppression is deliberate. Match the surrounding code.

## Before running the tests

**`./test/run.sh` deletes every boxy-managed container on the host**, including
stopped ones and including boxes the user is actively working in. It matches
`boxy.managed=1`, which every `boxy create` sets, so no naming scheme avoids
it. **Ask before running any suite.** Mounted directories are safe; the
containers are not.

## Invariants

Each of these breaks something that produces no error message when broken.

**The sidecar is created on `boxy-egress`, then attached to the internal net.**
Docker silently discards `-p` for a container whose only network is internal —
no error, empty binding list. Reverse the order and every published port on
every isolated box disappears with nothing in any log. Keep the
`docker run --network boxy-egress -p …` / `docker network connect boxy-iso-<name>`
sequence in that order.

**Isolation is a property of the docker network, never a check run inside the
box.** Do not add verification that shells into the container to confirm its
own isolation; the box owns every binary such a check could run. An earlier
design used `ip route` and was spoofable by a box with `sudo`.

**`CAP_NET_ADMIN` is never granted to a box.** It is what stops box root from
undoing its own network configuration.

**Allowlist entries are validated as domains at every entry point.** They
compile into POSIX EREs with only dots escaped, so an unvalidated `[^q]*`
becomes `^(.*\.)?[^q]*$` and matches everything. The current entry points are
`--allow`, `boxy allow`, and the allowlist file itself. A fourth one without
the check reopens this.

**The `boxy env` block goes at the *top* of `~/.bashrc`.** Debian ships
`case $- in *i*) ;; *) return;; esac` near the top; anything below it never runs
for `ssh box cmd`. Prepend, do not append.

**`~/.zshenv` is load-bearing.** zsh is the login shell, and Debian's
`/etc/zsh/zprofile` never sources `/etc/profile` — so `/etc/profile.d` does not
run for zsh at all. `~/.zshenv` is what sources it by hand, and it is the only
thing covering non-interactive `ssh box cmd`.

**`INSTALL_*` ARGs stay immediately above the `RUN` that reads them.** An `ARG`
in scope contributes to every later layer's cache key whether or not the layer
uses it. Hoisting them to the top of the Dockerfile makes `--claude` invalidate
the `apt` layer and re-download all of Debian. Nothing about this is visible in
the output; builds just get slow.

**The sidecar's PID 1 traps `SIGTERM`.** The kernel discards default-action
signals sent to PID 1, so an untrapped shell there never hears `docker stop`
and burns the full ten-second grace period.

**The proxying sidecar needs `CAP_KILL`.** tinyproxy drops to its own user, and
the supervisor has to signal it to reload the allowlist. Without it the reload
fails with `EPERM`.

**`boxy allow` waits for the sidecar to *see* the new policy before signalling.**
Bind-mounted writes are not instantly visible inside the container on Docker
Desktop. Signalling immediately reloads the old file and reports success. The
generation counter confirms a restart happened, not that it read the new bytes.

**No second variable for the config path.** `BOXY_CONFIG_DIR` moves the config
file and the allowlist together, on purpose. Two knobs would let them come
apart silently. It is also read from the environment only — a value inside the
config file cannot select the config file.

**`boxy logs` strips control characters unconditionally**, not just when
writing to a TTY, because the terminal is at the end of a pipeline boxy cannot
see. `--raw` is the opt-out.

**`--network` is refused as a `docker run` passthrough.** boxy owns the
network: `--net` picks it, the sidecar attaches to it, `boxy rm` tears it down,
and `boxy info` reports isolation by reading it.

## Docs

Four files, four questions. Put new prose where it answers the file's question:

| File | Answers |
| --- | --- |
| `README.md` | What is this, and how do I drive it? |
| `TOUR.md` | What does it look like running? |
| `DESIGN.md` | Why is it built this way? |
| `SECURITY.md` | What holds up when something is compromised? |

TOUR.md's premise is that **every block in it is real captured output**. Do not
add invented terminal output to it — capture it against a live daemon or put
the material in README/DESIGN instead.
