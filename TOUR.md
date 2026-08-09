# A tour of boxy

Every block below is real output captured on an arm64 Mac against a live
Docker daemon. Only the paths are edited: they came from a throwaway test
directory and have been rewritten to `~/.local/share/boxy`, if they land there during normal use.

Companion docs: [README.md](README.md) for reference, [DESIGN.md](DESIGN.md)
for why things are built the way they are, [SECURITY.md](SECURITY.md) for the
threat model. This file is the walkthrough.

---

## 0. The one-paragraph version

`boxy` gives you disposable Debian containers that behave like small remote
machines: you SSH into them with a known key, they have a scientific Python
stack preinstalled, they mount a directory of yours at `/work`, they expose
services either through an SSH tunnel that keeps the port number identical or
through an explicit docker-style `-p`, and their internet access can be
switched off or narrowed to an allowlist. Nothing secret is baked into the
image — keys, password hashes and proxy settings all arrive at
`docker run` time.

---

## 1. The surface

Commands are grouped by whether they are boxy's own or a thin wrapper over
docker:

```
$ boxy --help
boxy 1.0.0 — disposable SSH-reachable dev boxes

usage: boxy <command> [options]

CORE
  create [TARGET]            . | worktree | PATH, or nothing for scratch
  ssh [NAME] [-- CMD]        interactive session, or one command
  forward [NAME] [PORTS]     tunnel box ports to the SAME local ports
  rm NAME...                 remove a box (doesn't touch your files)
  ls                         list boxes
  images [-v]                build variants, which are built, what runs on them
  info [NAME]                one box in detail, config vs reality
  password [NAME]            print the stored sudo password
  env [NAME] [K=V ...]       list or set/inject env vars
  allow [NAME] [DOMAIN ...]  widen a running box's egress, no restart
  ssh-config [--install]     emit/install ssh_config for every box
  build [--full]             build the images
  doctor [--verbose]         check the local setup; -v adds per-box info
  config [--init]            show or scaffold configuration

DOCKER PASSTHROUGH — resolve the box name, then hand off to docker
  exec [NAME] [CMD]          adds defaults: as box user, at /work
  logs [NAME] [-f]           the box's entrypoint narration
  start|stop|restart [NAME]  lifecycle + ensures sidecar follows box
  top [--watch]              [docker stats] for boxes and sidecars

The name may be omitted whenever exactly one box exists.
Full options: boxy create --help, boxy build --help
```

"Exactly one box", in that last line, counts boxes rather than containers. A
`--net limited` box runs a proxy sidecar beside it, but name-omission looks
only at containers labelled `boxy.role=box`, so you can still leave the name
off.

The passthroughs are a convenience to resolve the box name and supply useful defaults  — `boxy exec` sets the box user,
`$HOME` and `/work`; `boxy start` brings the sidecar up alongside the box and
re-pins the host key. It's ok not to use them, the container name is
the box name, so `docker logs boxy-1` works exactly as you would expect. But just keep in mind that a box and its sidecar might get out of sync.

`boxy doctor` gives an overview of the `boxy` state and says whether the machine is ready to create a `boxy` instance. Some things are created lazily, and those are called out too:

```
$ boxy doctor
boxy 1.0.0

  docker cli               29.6.2
  docker daemon            reachable
  image boxy-base:latest   present (default)
  sidecar image            present (boxy-internalproxy:latest)
  boxy keypair             not yet generated (created on first boxy create)
  EFF wordlist             not cached (fetched on first create)
  config                   ~/.config/boxy/config
  state                    ~/.local/share/boxy
  boxes                    0

looks healthy
```

Running `boxy doctor -v` appends a full `boxy info` report for every box on the
system.

---

## 2. Creating a box

```
$ cd ~/code/demo && boxy create .

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

### What `boxy` creates on the host side

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
the directory you named, the worktree boxy created, or a fresh scratch dir
under `$TMPDIR/boxy/` when you named nothing.

Note that the keypair is in boxy's own state directory, not `~/.ssh`. boxy
creates and manages this key, so it belongs with boxy's other state, where
`rm -rf ~/.local/share/boxy` is a complete uninstall. Nothing boxy does writes
to `~/.ssh` unless you explicitly run `boxy ssh-config --install`. To supply
your own key instead, point `BOXY_SSH_KEY` at the **private** half — boxy
authorizes the `.pub` beside it and writes the private path into
`IdentityFile`:

```bash
BOXY_SSH_KEY=~/.ssh/id_ed25519 boxy create .   # authorizes ~/.ssh/id_ed25519.pub
```

### Where state lives

Boxy uses Docker labels as the single source of truth:

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

boxy reads these with `docker inspect --format` (Go templates); `boxy ls` is a `docker ps` filter over the same labels. This means that `docker` commands don't require extra steps to maintain Boxy's state.

---

## 3. Container sudo passwords

Container sudo passwords are four words drawn from the EFF long (7776-word) list, ~51.7 bits:

```
$ boxy password boxy-1
disarm-massager-uprising-shed

$ ls -l ~/.local/share/boxy/instances/boxy-1/password
-rw-------  ... password
```

What the container receives during creation:

```
BOXY_AUTHORIZED_KEYS=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEDW9yM2gHDe3cFzsiyaguS00s94foRUHYlixT…
BOXY_PASSWORD_HASH=$6$qvCefvsdcbTpEYGe$GdZm1Rcy47vYTxE3nsOrYtumw/Lrr1aj.Q4ivuSXoN8F5.QtbqADsINa…
```

The plaintext is hashed on the *host* with `openssl passwd -6` and only the
sha512-crypt hash crosses the boundary. The entrypoint feeds it to
`chpasswd -e` and then unsets it, so it appears in no image layer, no
`docker inspect`, and no `/proc/<pid>/environ`.

Word selection for the password uses rejection sampling against `/dev/urandom` rather than a plain modulo to prevent bias.

### The password gates sudo, not ssh

Inside the box it is an ordinary sudo password. The box user is added to the
`sudo` group at build time and no `NOPASSWD` rule is ever written, so `sudo`
really does ask:

```
$ boxy ssh boxy-1 -- 'sudo -n id'
sudo: a password is required

$ boxy ssh boxy-1 -- "echo $(boxy password boxy-1) | sudo -S id"
[sudo] password for boxyboy: uid=0(root) gid=0(root) groups=0(root)
```

`sshd` never accepts it: `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitRootLogin no`, plus an `AllowUsers`
line pinned to the box user. A box exposed on a public interface cannot be
brute-forced into.

---

## 4. Host keys are written to `known_hosts`

If `boxy ssh-config --known-hosts` is called, `boxy` writes  `~/.ssh/known_hosts` entries so that connecting is easier (and it's required for Claude Code Desktop). For example:

```
known_hosts:  [127.0.0.1]:2200 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXng2/CVus/zpHJAorQCcZ2T3KHwNaXakfEKwZpVVA4
hostkeys/:                    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXng2/CVus/zpHJAorQCcZ2T3KHwNaXakfEKwZpVVA4
```

They match because the source of truth, `<state>/hostkeys`, is bind-mounted into
the container. Boxy reads the box's public host key off the host filesystem and
writes a real `known_hosts` entry from it. Result: full host-key verification
from the first connection — no TOFU prompt, no `StrictHostKeyChecking=no`, and
the fingerprint survives `boxy restart`.

You only have to call `boxy ssh-config --known-hosts` once, and it'll keep boxy entries in your `~/.ssh/known_hosts` up to date for every future `boxy` usage; `boxy ssh-config --no-known-hosts` opts out of boxy managing this. Every time Boxy changes `~/.ssh/known_hosts`, it diffs the proposed and current `known_hosts`, and checks that every changed line contains the tag ` boxy:`.

---

## 5. Accessing a `boxy` container

`boxy ssh <name>` with no trailing command gives you a real login shell over ssh, on a real PTY:

```
$ boxy ssh boxy-1
Linux boxy-1 6.12.76-linuxkit #1 SMP Tue Jul 21 14:38:37 UTC 2026 aarch64

  boxy: boxy-1
  workdir: /work   user: boxyboy
  python: Python 3.12.13
  Bind servers to 0.0.0.0 (e.g. marimo edit --host 0.0.0.0) to reach
  them from the host on published ports.

boxy-1: (base) {4:45}/work $ whoami
boxyboy
boxy-1: (base) {4:45}/work $ tty
/dev/pts/0
boxy-1: (base) {4:45}/work $ echo $0
-zsh
boxy-1: (base) {4:45}/work $ echo $-
569XZilms
boxy-1: (base) {4:45}/work $ ls
notes.md  src
boxy-1: (base) {4:45}/work $ exit
Connection to 127.0.0.1 closed.
```

Three things to call out from the above. `/dev/pts/0` is a genuine
pseudo-terminal; the leading dash in `-zsh` marks a login shell; the `i` in
`569XZilms` marks an interactive one. Together they mean job control, `Ctrl-C`,
`Ctrl-Z`, curses programs and window resizing all behave normally. In the
prompt itself, `(base)` is the active conda environment and `/work` is where
you land.

`boxy ssh` resolves the name, then finishes with `exec ssh -F <state>/ssh_config
<name>` — it replaces itself with the `ssh` client rather than spawning one as a
child. So no boxy process sits between you and the session: exit codes come back
unchanged, `Ctrl-C` reaches the remote command, and SSH's own `~.` escape works,
the same as if you had typed that `ssh` command yourself. That holds for both
forms.

Add a command and you get a one-shot, non-interactive run instead of a live interactive one. There is no PTY and no
prompt: the command runs, its output comes back, and the connection closes —
which is the mode scripts might want.

```
$ boxy ssh boxy-1 -- tty
not a tty
$ boxy ssh boxy-1 -- pwd
/work
$ boxy ssh boxy-1 -- 'echo $0'
zsh
$ boxy ssh boxy-1 -- 'python -c "print(2**16)"'
65536
```

Note the `$0`: `zsh` here, against `-zsh` in the session above. The leading
dash is how a shell is told it is a login shell, so its absence means this one
is not — which is the case "Environment variables the box sees" below is about.

Both forms land in `/work`. Note that `/work` is a directory — the mount
point for a temporary directory on the host, or whatever you named, be it a directory or a worktree:

```
$ boxy ssh boxy-1 -- 'stat -c %F /work; ls -la /work'
directory
total 8
drwxr-xr-x 4 boxyboy boxyboy  128 Aug  8 04:44 .
drwxr-xr-x 1 root    root    4096 Aug  8 04:44 ..
-rw-r--r-- 1 boxyboy boxyboy   13 Aug  8 04:44 notes.md
drwxr-xr-x 3 boxyboy boxyboy   96 Aug  8 04:44 src
```

### What is in the default `base` image

```
  python   3.12.13
  jax      0.11.0 backend: cpu | devices: [CpuDevice(id=0)]
  numpy    2.5.1  scipy 1.18.0  pandas 3.0.5
  marimo   0.23.16
  node       v26.6.0
  npm        11.18.0
  uv         0.12.2
  conda      26.7.0
  mamba      2.5.0
  git        2.39.5
  rg         13.0.0
```

`base` is what you get by default. The heavier variants add to it — Claude Code
lives in `claude`, and `extras` and `full` pull in the rest of the usual
scientific stack. Run `boxy images` to see which are built.

Real work over that same one-shot form — no PTY, nothing interactive, just a
command and its output:

```
$ boxy ssh boxy-1 -- 'python -c "..."'
  jit-compiled 512x512: 134217728.0
  grad: 0.5403022766113281
```

### Most things don't need sudo

The three directories you actually work in all belong to the box user:

```
$ boxy ssh boxy-1 -- 'stat -c "  %U:%G %n" /home/boxyboy /opt/conda /work'
  boxyboy:boxyboy /home/boxyboy
  boxyboy:boxyboy /opt/conda
  boxyboy:boxyboy /work
```

So installing a package is just installing a package:

```
$ boxy ssh boxy-1 -- 'pip install -q seaborn && python -c "import seaborn, os; ..."'
  seaborn 0.13.2 -> /opt/conda/lib/python3.12/site-packages/seaborn
  boxyboy owns /opt/conda
```

The conda prefix is owned by the box user because everything is installed as
that user at build time. The default build is **2.25 GB** as it stands.

### The mounted directory is live in both directions

A file written on the host is readable in the box immediately, and the reverse:

```
$ echo "written on the host" > ~/code/demo/from-host.txt
$ boxy ssh boxy-1 -- 'cat /work/from-host.txt'
written on the host

$ boxy ssh boxy-1 -- 'echo "the answer is 42" > /work/results.txt'
$ cat ~/code/demo/results.txt
the answer is 42

$ ls ~/code/demo
from-host.txt  notes.md  results.txt  src
```

Neither direction copies anything: `/work` *is* that host directory, so there
is no sync step to wait for and nothing to go stale.

### Environment variables the box sees

`boxy env` sets variables that persist for the life of the box and reach every
way of getting into it — new ssh sessions, `boxy exec`, and one-shot commands:

```
$ boxy env demo API_KEY=secret REGION=us-east-1
demo now has 2 variable(s) set
new ssh sessions and 'boxy exec' see them; they survive a restart
in a session already open: . /etc/profile.d/boxy-env.sh

$ boxy env demo
API_KEY=secret
REGION=us-east-1

$ boxy ssh demo -- 'echo $API_KEY'
secret
```

Boxy manages environment variables a bit differently from `docker run -e`. A variable set via `-e` lands in PID 1's
environment, which the box's own processes and `boxy exec` inherit — but an ssh
session does not, because sshd builds a fresh environment through PAM rather
than inheriting PID 1's. And `-e` is fixed for the life of the container, so
adding a variable would mean recreating the box.

So boxy keeps the variables in a file instead. `boxy env` writes
`/etc/boxy-env` (plain `KEY=VALUE`, one per line) and the entrypoint installs a
loader at `/etc/profile.d/boxy-env.sh` that reads it. Login shells run
everything in `/etc/profile.d`, so an interactive `boxy ssh` is covered for
free.

The awkward case is `ssh box cmd`, which is neither a login shell nor an
interactive one and so reads no profile at all. Boxy covers it through the
box user's login shell: zsh reads `~/.zshenv` on *every* invocation, and boxy's
block there sources `/etc/profile.d` by hand. (The entrypoint writes an
equivalent block at the top of `~/.bashrc`, so the variables are still there if
you switch the shell to bash.)

There is no host-side copy of environment variables and nothing replayed on start: the file lives in the
container, so it survives a restart untouched — and can be read back while the
box is stopped, since boxy lifts it out with `docker cp` rather than needing
anything running to ask:

```
$ boxy stop demo && boxy env demo
API_KEY=secret
REGION=us-east-1
```

`PATH` and `BOXY_*` are refused — the first because replacing the box's own `PATH`
breaks every command in it, the second because that is boxy's channel into the
entrypoint:

```
$ boxy env demo PATH=/evil
error: env: refusing 'PATH' — names must be identifiers, and PATH and BOXY_* belong to boxy
```

---

## 6. Ports

Only SSH is published automatically: instance *N* gets `2200 + N - 1`.

```
$ boxy create -n api
created instance 2 (api), ssh at port 2201
  ports   none published — boxy forward api tunnels 2718 8888 8000 8080 ...

$ boxy create -n scratch
created instance 3 (scratch), ssh at port 2202
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

### Two ways to reach a service

**`boxy forward`** tunnels a port over ssh to the box, keeping the *same* number
on the host: 8000 in the box is 8000 on your machine. This can be done at any
time in the box's life cycle. (On an isolated box that ssh connection runs
through the sidecar, which changes nothing here — §7 has the details.)

```
$ boxy forward boxy-1 --bg 8000
tunnelling 8000 in the background (boxy forward boxy-1 --stop to end)

$ curl localhost:8000
results.txt

$ boxy forward boxy-1 --stop
stopped tunnel for boxy-1
```

`--stop` takes no port: it ends every tunnel recorded for the box. Stopping one
of several would leave the rest running with no way left to name them. Ports
are positional arguments — `boxy forward [NAME] [--bg|--stop] [PORT ...]` — and
omitting them forwards boxy's default list.

`--bg` is **additive**. A second call adds ports to what is already tunnelled
rather than replacing it, and a port an earlier tunnel already holds is skipped
with a warning rather than treated as an error:

```
$ boxy forward boxy-1 --bg 8000
tunnelling 8000 in the background (boxy forward boxy-1 --stop to end)

$ boxy forward boxy-1 --bg 8000 8080
warning: localhost:8000 is already in use — skipping
tunnelling 8080 in the background (boxy forward boxy-1 --stop to end)
1 other tunnel(s) already up for boxy-1 — --stop ends all of them

$ boxy forward boxy-1 --stop
stopped 2 tunnels for boxy-1
```

Note that the message names 8080 alone: what a call reports is what it actually
tunnelled, not what you asked for. If every port you name is already up there is
nothing left to do, and the command says so rather than starting an empty
tunnel:

```
$ boxy forward boxy-1 --bg 8000
warning: localhost:8000 is already in use — skipping
error: no ports available to forward
```

The pid bookkeeping exists only because of `--bg`. Without it, `boxy forward`
runs in the foreground and you stop it with `Ctrl-C`. With it, boxy starts
`ssh -N -T` with its output appended to `<state>/forward.log`, detaches it
from the terminal and returns — leaving a plain background process that nothing
is waiting on, so boxy appends its pid to the list in `<state>/forward.pid`.
But a tunnel can also die on its own — a dropped network,
`ExitOnForwardFailure`, a reboot — which leaves a record pointing at a pid the
OS is free to hand to something else. So each pid is confirmed to still be
*that* tunnel before it is signalled, rather than killing whatever now holds the
number:

```
$ boxy forward boxy-1 --stop
no tunnel running for boxy-1 — cleared a stale record (pid 59360)
```

**`-p`** publishes, with exactly docker's semantics — a bare port means the
same number, `HOST:CONTAINER` states it explicitly. It is a `boxy create` flag
only: publishing is fixed when the container is made, whereas `boxy forward`
works on a box that already exists.

```
$ boxy create -n pub -p 28000:8000 -p 29999
$ boxy info pub
published   localhost:28000 -> 8000   localhost:29999 -> 29999
forwardable 2718 8888 8000 8080 3000 5000 6006   (boxy forward pub)
```

A taken host port causes an error before anything is created, not a silent remap:

```
$ boxy create -n dup -p 28000:8000
error: --publish 28000:8000: host port 28000 is already in use
```

> Servers in the box must bind `0.0.0.0` to be reachable through a port
> published with `-p` (`marimo edit --host 0.0.0.0`). Docker forwards such a
> port from the host into the container's network interface, and a server bound
> to `127.0.0.1` is not listening there. Binding `127.0.0.1` is fine over
> `boxy forward`, because that tunnel terminates *inside* the container, on the
> same loopback the server is on.

---

## 7. Limiting internet access

```
boxy create --net full      # default, unrestricted
boxy create --net none      # no route off the host
boxy create --net limited   # allowlisting proxy only
```

### How: Docker internal networks

Isolated means **either** `--net none` **or** `--net limited` — both get the
same treatment, and only `--net full` is different. Anything other than `full`
puts the box alone with its sidecar on a `docker network create --internal`
network. Docker installs no default route for it, no NAT rule for its subnet,
and no external DNS. That is the entire mechanism for isolation. Container
names on that network still resolve — that is how the sidecar finds the box —
but no external name does.

The two modes differ only in what the sidecar does once it is there: under
`--net none` it relays ports inward and nothing else, and under `--net limited`
it also runs a proxy the box is allowed to reach.

Isolation belongs to the network rather than to the running container, so no
step has to be reapplied when a box restarts, and nothing done inside a box can
lift it:

```
  ssh works on an isolated box       PASS
  no default route                   PASS
  https blocked                      PASS
  raw IP blocked                     PASS
  the box's network is internal      PASS
  the box binds no host ports        PASS
  external name resolution is dead   PASS   <- DNS covert channel, closed for free
  TXT lookups cannot smuggle data    PASS
  still isolated after a raw restart PASS   <- plain docker restart included
  box root cannot undo it            PASS   -> RTNETLINK: Operation not permitted
```

### Securing the sidecar against the box

Docker will not bind a host port for a container whose only network is
internal: `-p` is accepted and silently discarded — no error, an empty binding
list, and `docker port` prints nothing. So the box itself publishes nothing,
and a per-box sidecar holds its ports instead.

Being on two networks is not by itself enough — what matters is the order the
sidecar acquires them. It is created with `docker run --network boxy-egress
-p …`, where `boxy-egress` is an ordinary bridge. At that moment its only
network is a normal one, so Docker binds the host ports without complaint. Only
*afterwards* does boxy run `docker network connect boxy-iso-<name>` to attach
the box's internal network.

Here are the two possible orders:

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

That leaves the sidecar as the one container on both networks, which makes it
the obvious thing for a compromised box to attack.

It is a poor target, because traffic only ever flows host → sidecar → box. The
sidecar never needs to accept a connection *from* the box, so its `socat`
listeners are bound to one specific address: the sidecar's address on
`boxy-egress`, the interface that owns its default route. Nothing is listening
on the address the box can actually see — its side of `boxy-iso-<name>` — so
from inside the box those ports are not filtered, they are simply not there:

```
box -> sidecar:2200 (by IP)    REFUSED
box -> sidecar:2200 (by name)  REFUSED
port scan 22 / 80 / 2200 / 8888  all closed
default route via sidecar, then egress   BLOCKED
```

It also runs with `--cap-drop=ALL` (`CapBnd:0000000000000000`) and
`net.ipv4.ip_forward=0`, so there is nothing to escalate to and the kernel
will not route through it. That is not the same as being unable to relay —
see §13 — but it does mean the box gets no help from the sidecar's privileges.

### Reaching a new port on an isolated box

Because those host bindings are fixed when the sidecar is created, `-p` cannot
add a port to an isolated box after the fact. `boxy forward` works by tunnelling over ssh through the one port the sidecar already binds.

The `ssh` client on your machine connects to `127.0.0.1:2200`, a port the
sidecar holds — so the TCP connection really is *to* the sidecar. But the
sidecar's `socat` is a plain byte relay, `TCP-LISTEN:2200` spliced to
`TCP:boxy-1:22`, copying bytes onto the internal network without decrypting or
interpreting any of them. The SSH handshake, the authentication and the session
all terminate at the *box's* sshd.

`ssh -L 8000:127.0.0.1:8000` is therefore two things at once: a property of the
`ssh` process on your machine, which listens on `127.0.0.1:8000` there, and an
instruction to the box's sshd, which opens `127.0.0.1:8000` from inside the box
and splices the two together over the tunnel. The port "expands" into a real
connection once it reaches the box; in between it is a multiplexed channel
inside the one encrypted stream already running through the sidecar.

So the sidecar sees a single TCP connection and never learns that 8000 exists —
which is exactly why no new host binding and no sidecar restart are needed. It
behaves the same as on a `--net full` box, where no sidecar is in the path at
all:

```
$ boxy create ~/code/demo --net none
created instance 1 (boxy-1), ssh at port 2200
  net     none (sidecar boxy-sidecar-boxy-1)

$ boxy forward boxy-1 --bg 8000
tunnelling 8000 in the background (boxy forward boxy-1 --stop to end)

$ curl -o /dev/null -w '%{http_code}\n' localhost:8000
200
```

This does not weaken the isolation. The tunnel carries traffic *into* the box
over a connection the host opened; it gives the box no way out. The one
exception is `--net limited`, where the box *can* reach the proxy port on the
sidecar, which is what `limited` means.

### `--net limited`

In this case, a per-box tinyproxy sidecar sits on both the box's subnet and a normal bridge,
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
$ boxy logs --sidecar ltd
NOTICE  Proxying refused on filtered domain "example.com"
```

A blocked **HTTPS** request shows up as `curl` exit 7 / status `000`, not a
403 — HTTPS goes through as `CONNECT` and tinyproxy refuses by dropping the
tunnel, so there is no HTTP response to carry a status. Plain HTTP returns a
real 403.

The shipped allowlist covers PyPI, conda-forge, GitHub, npm, Debian, Hugging
Face and the Anthropic API.

### Changing the policy without dropping the session

The shared allowlist is read once, at create, and copied to a file on the sidecar — editing it on the host only affects the *next* box, rather than rewriting the rules
for running boxes. To widen a box that is running, use `boxy allow`:

```
$ boxy allow ltd example.com
ltd may now reach 25 domain(s)
this box only — ~/.config/boxy/allowlist.txt is unchanged, so new boxes are unaffected
live ssh sessions and forwards are untouched
```

Keeping ssh sessions alive is a source of complexity in Boxy's sidecar design.
The box's ssh port is carried by `socat` inside the same sidecar the proxy
lives in, so restarting the sidecar would drop every session and forward it is
holding. Instead the box's copy of the policy is bind-mounted **read only**
into the sidecar, whose PID 1 is a supervisor rather than tinyproxy itself: on
`SIGHUP` it rebuilds the filter and restarts *only* tinyproxy. (It has to be a
restart. tinyproxy compiles its filter once at startup, and its own `SIGHUP`
handler re-reads the config file and then goes on enforcing the old policy.)

Two things make that read-only mount worth more than a gesture. The allowlist
is the *only* input to the filter, so there is no second file to point at
instead; and `socat` — the process on the receiving end of every inbound
connection, and so the most exposed thing in the sidecar — is dropped to
`nobody` with `setpriv`, specifically so a compromise there cannot kill
tinyproxy and stand up an unfiltered proxy in its place. Full root inside the
sidecar is a different matter, and §13 says so plainly.

Entries in the allowlist are domains, not patterns. The filter is a list of regexes and only
dots are escaped on the way in, so `[^q]*` would otherwise become
`^(.*\.)?[^q]*$` and match everything. Every route into the list gets the same
check, `--allow` and the file alike:

```
$ boxy allow ltd '*.example.com'
error: allow: '*.example.com' — drop the '*.', subdomains are already included
```

---

## 8. Using a box over ssh

`boxy` regenerates a standalone `ssh_config` on every create/remove:

```
# Generated by boxy 1.0.0 — regenerated on every create/rm.
# Do not edit; put overrides in ~/.config/boxy/config.

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

Run the following once and `~/.ssh/config` will `Include` that file from then on:

```bash
boxy ssh-config --install
```

After that, `ssh api` works from anything that speaks SSH — verified with
`ssh`, `scp` and `rsync` — which is what lets Claude Code or VS Code
Remote-SSH treat a box as an ordinary remote host. Pair it with
`boxy ssh-config --known-hosts` from §4 if the client insists on reading
`~/.ssh/known_hosts` rather than the per-box file (Claude Desktop does this).

`boxy exec` is the escape hatch that does not involve SSH at all:

```
$ boxy exec boxy-1 'echo "exec as $(whoami), HOME=$HOME, cwd=$(pwd)"'
exec as boxyboy, HOME=/home/boxyboy, cwd=/work
```

---

## 9. Monitoring

`boxy top` reads straight from the daemon — no extra services and nothing to start first, but also no retention:

```
$ boxy top
NAME      CPU %     MEM USAGE / LIMIT    MEM %     NET I/O
scratch   0.01%     2.219MiB / 7.75GiB   0.03%     6.32kB / 5.44kB
api       0.03%     12.93MiB / 7.75GiB   0.16%     14.1kB / 12.9kB
boxy-1    0.04%     14.94MiB / 7.75GiB   0.19%     35.3kB / 34.8kB
```

`boxy top --watch` keeps it updating.

---

## 10. Lifecycle and the working directory

```bash
boxy stop|start|restart <name>
boxy logs <name> -f          # the entrypoint narrates every step here
boxy logs --sidecar <name>   # the other half: denials and ingress listeners
boxy logs -v <name>          # every connection through the ingress relay
boxy logs --raw <name>       # without the control-character stripping
boxy rm <name>
```

`boxy logs` is `docker logs` of the box: the entrypoint's setup narration —
host-key generation, authorized-keys install, password set, isolation
confirmed. Look here first when a box misbehaves. A setup step that fails
leaves the box *running* rather than dead, so you can still get in and read
why.

An isolated box's logs are split across two containers, because everything
that can fail on the way into the box's network, or out of it, lives on the
sidecar. Read the
sidecar's half with `boxy logs --sidecar`. This contains the ingress listeners it placed, the allowlist it
compiled, and every domain it later refused. When a request from the box times
out and the box's own log has nothing to add, the reason should be here.

The default `boxy logs` and `boxy logs --sidecar` logs answer "did something break". `--verbose` gives the
per-connection audit trail for the ingress relay. It lives in a file inside
the sidecar, so a dozen lines per connection never bury the faults, and it
stays readable after the sidecar has stopped — the case it exists for. See [SECURITY.md](SECURITY.md) for notes on how these logs are stored and sanitized.

### Where your files live

```bash
boxy create .              # mount a directory you own
boxy create worktree       # a fresh branch of the repo you are in
boxy create                # fresh scratch dir in $TMPDIR/boxy/
```

Given a path, that directory is mounted at `/work` as-is — never created, moved, nor deleted. When given neither a path nor `worktree`, boxy makes a fresh directory under
`$TMPDIR/boxy/<name>.XXXXXX` (`mktemp`, so a recreated box never inherits a
previous one's leftovers). Temp directories are left to 
the OS to reap.

### `boxy rm`

One behaviour, no flags:

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
file. None of that means anything once the box is gone, and because `rm` cannot
destroy any mounted files, any work in `/work` persists. Files stored outside
`/work` — in `$HOME`, say — live only in the container's writable layer and
**will** be deleted without a prompt.

If you are unsure whether a box has anything worth keeping outside `/work`,
`docker diff` lists every path that container has added or changed since the
image, and it works on a stopped container:

```bash
docker diff boxy-1 | grep -v '^C' | grep -v '^A /work'
```

Recreating a box under the same name gets a fresh host key and a fresh
password; nothing is adopted from the removed one.

---

## 11. Container privileges

Boxes run with a reduced kernel capability set by default — 10 of Docker's default 14:

```
$ boxy info boxy-1 | grep caps
caps        minimal

$ docker exec boxy-1 sh -c 'capsh --decode=$(grep CapBnd /proc/1/status|cut -f2)'
cap_audit_write cap_chown cap_dac_override cap_fowner cap_kill
cap_net_bind_service cap_net_raw cap_setgid cap_setuid cap_sys_chroot
```

Dropped: `MKNOD`, `SETPCAP`, `SETFCAP`, `FSETID`. Nothing in a dev box has a
plausible use for creating device nodes or editing capability sets.

The set favours usability over provable minimality. Dropping further capabilities produced at least slightly confusing failures during testing. For example, when `NET_RAW` is not granted:

```
$ ping -c1 127.0.0.1
exec /usr/bin/ping: operation not permitted
```

`/usr/bin/ping` carries the file capability `cap_net_raw=ep`. The `e`
(effective) bit means that when `NET_RAW` is outside the bounding set, `exec`
of the binary fails outright — not a degraded ping, a binary that will not
start, reporting an error that never mentions `NET_RAW`.

The sharp part is that ping does not even need the capability. The image has
`net.ipv4.ping_group_range = 0 2147483647`, so any process can already open the
unprivileged ICMP datagram socket ping actually uses; no raw socket is
involved. The failure comes entirely from the `e` bit being checked at `exec`,
before the program runs and discovers it had another way. `KILL` is the same
kind of story (`sudo pkill` silently fails without it), as are
`NET_BIND_SERVICE` and `AUDIT_WRITE`.

Verified still working under the reduced set: ssh login, sudo to uid 0, ping,
binding port 80 as an unprivileged user, `pip install`, and `git commit`.

`boxy create --caps docker-default` restores Docker's full 14. This can help
debug if kernel capabilities are causing issues. Note which is which:
`minimal` is boxy's default, and `docker-default` names Docker's own set. The
value used to be spelled `default`, which read backwards — it named the set you
never got by default. That spelling is rejected outright, with an error naming
the replacement: it differs from boxy's actual default by ten capabilities, and
guessing wrong about which one you get is not a mistake worth being quiet about.

---

## 12. Test status

```bash
./test/run.sh              # every suite
./test/run.sh core         # just one
```

```
core: 108 passed, 0 failed
network: 65 passed, 0 failed
workflow: 114 passed, 0 failed

========== summary ==========
  ok     core
  ok     network
  ok     workflow

all suites passed
```

287 assertions, all green. The suites run against a scratch `BOXY_STATE_DIR`
under `$TMPDIR` with their own keypair, so they cannot touch a real install or
your `~/.ssh`.

One warning: **running `./test/run.sh` removes every boxy-managed container on
the host.** Stopping a box first does not save it; the purge matches stopped
containers too. Your mounted directories are untouched, but the boxes
themselves are gone.

A test-only naming scheme would not fix this, because the suite is testing
boxy's own behaviour rather than just its output. It has to run `boxy create`,
which sets `boxy.managed=1` whatever the box is called, and several assertions
are about *global* daemon state — "the name may be omitted when exactly one box
exists" is only true, and only testable, when the daemon holds exactly one
boxy box. A shared Docker daemon is the one resource the suite cannot sandbox.

| Suite | Covers |
| --- | --- |
| `core` | creation, the box interior, the volume, sudo, sshd hardening, host-key pinning, capability policy, symlinked install, rollback of a failed create, the zsh login shell and its prompt, variant image tagging, `boxy images` |
| `network` | `--net none` / `--net limited`, DNS and on-link hardening, restart persistence, the allowlist and `boxy allow`, domain validation, teardown |
| `workflow` | ports and `-p`, forwarding, `ssh_config`, `exec`, `boxy env`, the rm/workdir contract |

---

## 13. Known gaps

- **boxy is local-only by design.** There is no remote-host story — no
  Tailscale, no `--runtime runsc` (gVisor), no `BOXY_SSH_HOST`, no metrics
  stack. boxy only ever talks to `docker`, so `docker context create vps
  --docker "host=ssh://…"` is the obvious re-entry point if you want one.
- **JAX is CPU-only.** GPU needs a CUDA build target and `jax[cuda12]`
  (amd64 only).
- **`--net limited`/`none` are guardrails, not a pure sandbox.** An isolated box
  cannot reach the internet, the host, or another box. It *can* do whatever it
  likes with mounted directories. The allowlist for a  `--net limited` box constrains where you can talk rather than what you can say — a POST
  from a limited box reaches `api.github.com` and gets a real answer.
- **A worktree box can rewrite your local git history.** It has the repo's
  object store mounted read-write, so it can move branches and delete objects.
  It carries no credentials, so the damage stops at your machine.
- **Isolated boxes are capped by Docker's address pools.** Each `--net none` or
  `--net limited` box gets its own network, and Docker's defaults run out
  somewhere around two to three dozen of them. A create that hits the ceiling
  fails with the daemon's own message and rolls back cleanly, but the ceiling
  is Docker's to raise (`default-address-pools` in `daemon.json`), not boxy's.
- **The sidecar is a trust boundary, not a sandbox.** It is dual-homed
  (`boxy-egress`, an ordinary bridge with real internet access, and
  `boxy-iso-<name>`, the box's internal network) by design, so a compromised
  one can relay the box's traffic entirely in userspace: a process that reads
  from one socket and writes to another needs no capabilities, and
  `net.ipv4.ip_forward=0` only stops the *kernel* from routing, which such a
  relay never asks it to do. Under
  `--net none` the box has no way to reach the internet, which contains a `--net none` box even if it's compromised; under `--net limited` the box must reach tinyproxy, which is necessarily an attack surface in this design. §7 and [SECURITY.md](SECURITY.md) go into more detail.
