#!/usr/bin/env bash
# Workflow: ports, forwarding, repo cloning, ssh_config, exec, and the
# rm/recreate state contract.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env

WORK="$TEST_TMP/work-wf"
rm -rf "$WORK"; mkdir -p "$WORK"
echo "marker" > "$WORK/marker.txt"

section "ports are not published unless asked"
boxy create "$WORK" >/dev/null 2>&1
assert_contains "info reports none published" "(none)" "$(boxy info boxy-1)"
assert_empty "docker publishes only ssh" \
    "$(docker port boxy-1 | grep -v '^22/tcp' || true)"

section "-p publishes with a stated mapping"
boxy create -n pub -p 28000:8000 -p 29999 >/dev/null 2>&1
info_out="$(boxy info pub)"
assert_contains "explicit host:container shown" "localhost:28000 -> 8000" "$info_out"
assert_contains "bare port means the same number" "localhost:29999 -> 29999" "$info_out"
docker exec -d -u boxyboy pub sh -c 'cd /work && python -m http.server 8000 --bind 0.0.0.0'
sleep 3
assert_eq "the published port actually serves" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:28000/)"

section "-p rejects a port already in use"
assert_contains "clear error, no container left behind" "already in use" \
    "$(boxy create -n dup -p 28000:8000 2>&1)"
assert_empty "nothing was created" "$(docker ps -aq -f name='^dup$')"

section "boxy forward keeps the number identical"
docker exec -d -u boxyboy boxy-1 sh -c 'cd /work && python -m http.server 8000 --bind 0.0.0.0'
sleep 3
boxy forward boxy-1 --bg 8000 >/dev/null 2>&1
sleep 3
assert_eq "localhost:8000 reaches the box's :8000" "200" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/)"
boxy forward boxy-1 --stop >/dev/null 2>&1
sleep 1
assert_eq "tunnel is gone after --stop" "000" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8000/ 2>/dev/null)"

section "boxy create worktree"
# A worktree's .git is a file naming an absolute host path, so the box only
# gets a working repo because boxy also mounts the shared git dir at that
# same path. Everything here fails if that mount is missing or misplaced.
REPO="$TEST_TMP/repo"
rm -rf "$REPO"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@example.com \
    && git config user.name Tester && echo base > base.txt \
    && git add . && git commit -qm "base" ) >/dev/null 2>&1
# Whatever git calls the first branch here — it varies by version and by the
# user's init.defaultBranch, and this suite must not care.
MAIN_BRANCH="$(git -C "$REPO" branch --show-current)"
( cd "$REPO" && boxy create worktree -n wt ) >/dev/null 2>&1
wt_wd="$(boxy info wt | awk '/^workdir/{print $2}')"

assert_contains "the checkout is in /work"  "base.txt" "$(bssh wt 'ls /work')"
assert_eq "on its own branch" "boxy/wt" "$(bssh wt 'git -C /work branch --show-current')"
assert_contains "and it can see the repo's history" "base" \
    "$(bssh wt 'git -C /work log --oneline')"
assert_contains "info names the branch" "boxy/wt" "$(boxy info wt)"

section "a commit in the box is a commit in your repo"
bssh wt 'cd /work && echo from-the-box > new.txt && git add new.txt &&
         git -c user.email=b@example.com -c user.name=Box commit -qm "box commit"' >/dev/null
assert_contains "the host repo has it on the branch" "box commit" \
    "$(git -C "$REPO" log --oneline boxy/wt)"

section "info catches a branch renamed behind boxy"
# /work and the git dir are bind mounts, so the host reads the branch from the
# same bytes the box does. Nothing here may reach into the container: this must
# hold on a box that is not even running.
assert_empty "quiet while the box is healthy" "$(boxy info wt | grep '⚠' || true)"
git -C "$REPO" branch -m boxy/wt renamed-behind-boxy
out="$(boxy info wt)"
assert_contains "the label is still shown"   "boxy/wt"              "$out"
assert_contains "with reality beside it"     "renamed-behind-boxy"  "$out"

section "and it sees a checkout made inside the box"
git -C "$REPO" branch -m renamed-behind-boxy boxy/wt
boxy exec wt 'cd /work && git checkout -q -b from-inside' >/dev/null 2>&1
assert_contains "same bytes, so the host sees it" "from-inside" "$(boxy info wt)"

section "the branch check works on a stopped box"
# The point of doing this on the host: docker exec cannot run at all here.
boxy stop wt >/dev/null 2>&1
out="$(boxy info wt)"
assert_contains "box really is stopped"  "exited"      "$out"
assert_contains "and the drift is still reported" "from-inside" "$out"
boxy start wt >/dev/null 2>&1
boxy exec wt 'cd /work && git checkout -q boxy/wt' >/dev/null 2>&1

section "doctor --verbose reports every box"
out="$(boxy doctor --verbose 2>&1 || true)"
assert_contains "names the box"            "wt"          "$out"
assert_contains "includes its detail"      "forwardable" "$out"
assert_empty "plain doctor stays a summary" \
    "$(boxy doctor 2>&1 | grep 'forwardable' || true)"

section "the worktree does not expose your main checkout"
assert_eq "the main working tree was never mounted" "absent" \
    "$(bssh wt "[ -e '$REPO/base.txt' ] && echo present || echo absent")"
assert_eq "your checkout is unchanged" "absent" \
    "$( [ -e "$REPO/new.txt" ] && echo present || echo absent )"
assert_eq "and still on its own branch" "$MAIN_BRANCH" \
    "$(git -C "$REPO" branch --show-current)"

section "rm retires the worktree but never the work"
boxy rm wt >/dev/null 2>&1
assert_eq "the checkout is gone" "gone" \
    "$( [ -d "$wt_wd" ] && echo present || echo gone )"
assert_contains "the branch survives with the commit on it" "box commit" \
    "$(git -C "$REPO" log --oneline boxy/wt)"
# Count rather than match paths: git reports the physical path
# (/private/var/...) where the shell holds the logical one (/var/...), so
# comparing the two strings is a test that fails for the wrong reason.
assert_eq "and the repo has only its own worktree left" "1" \
    "$(git -C "$REPO" worktree list | grep -c .)"

section "a dirty worktree is left alone"
( cd "$REPO" && boxy create worktree -n dirty ) >/dev/null 2>&1
dirty_wd="$(boxy info dirty | awk '/^workdir/{print $2}')"
bssh dirty 'echo uncommitted > /work/scratch.txt' >/dev/null
out="$(boxy rm dirty 2>&1)"
assert_contains "rm says so rather than discarding it" "uncommitted changes" "$out"
assert_file_contains "the file is still there" "$dirty_wd/scratch.txt" "uncommitted"
git -C "$REPO" worktree remove --force "$dirty_wd" >/dev/null 2>&1 || true

section "worktree needs a repo, and --ref needs a worktree"
assert_contains "outside a repo it says so" "must be run inside a git repository" \
    "$( cd "$TEST_TMP" && boxy create worktree -n nope 2>&1 )"
assert_contains "--ref alone is refused" "only means something" \
    "$(boxy create -n nope2 --ref main 2>&1)"

section "ssh_config works for anything that speaks ssh"
boxy ssh-config >/dev/null 2>&1
assert_file_contains "has a Host block"      "$SSH_CFG" "Host boxy-1"
assert_file_contains "pins the identity"     "$SSH_CFG" "IdentitiesOnly yes"
assert_file_contains "verifies the host key" "$SSH_CFG" "StrictHostKeyChecking yes"
rm -f "$TEST_TMP/fetched.txt"
scp -F "$SSH_CFG" -q boxy-1:/work/marker.txt "$TEST_TMP/fetched.txt" 2>/dev/null
assert_file_contains "scp fetched the right contents" "$TEST_TMP/fetched.txt" "marker"

section "boxy exec (no ssh in the path)"
assert_contains "runs as the box user with a correct HOME" "HOME=/home/boxyboy" \
    "$(boxy exec boxy-1 'echo HOME=$HOME')"
assert_eq "conda is on PATH here too" "/opt/conda/bin/python" \
    "$(boxy exec boxy-1 'command -v python')"
# Without a terminal an interactive shell has nothing driving it and `bash -l`
# blocks forever, so this must fail with a reason rather than hang.
assert_contains "no command and no tty fails fast" "needs a terminal" \
    "$(boxy exec boxy-1 < /dev/null 2>&1)"

section "a default workdir is scratch space in the OS temp area"
boxy create -n scratch1 >/dev/null 2>&1
scratch_wd="$(boxy info scratch1 | awk '/^workdir/{print $2}')"
assert_contains "lives under the temp base" "$BOXY_WORKDIR_BASE" "$scratch_wd"
assert_eq "and it really exists" "yes" "$( [ -d "$scratch_wd" ] && echo yes || echo no )"
boxy create -n scratch2 >/dev/null 2>&1
wd2="$(boxy info scratch2 | awk '/^workdir/{print $2}')"
assert_eq "each box gets its own, never a shared path" "different" \
    "$( [ "$scratch_wd" != "$wd2" ] && echo different || echo same )"

section "rm removes the box and its bookkeeping, and nothing of yours"
bssh scratch1 'echo kept > /work/mine.txt' >/dev/null
boxy rm scratch1 >/dev/null 2>&1
assert_empty "container gone" "$(docker ps -aq -f name='^scratch1$')"
assert_empty "boxy's per-instance state gone" \
    "$(ls -d "$BOXY_STATE_DIR/instances/scratch1" 2>/dev/null)"
assert_eq "the scratch workdir is left for the OS to reap" "yes" \
    "$( [ -d "$scratch_wd" ] && echo yes || echo no )"
assert_file_contains "and your files are still in it" "$scratch_wd/mine.txt" "kept"

section "a mounted directory is never touched"
boxy rm boxy-1 >/dev/null 2>&1
assert_file_contains "your mounted files survive" "$WORK/marker.txt" "marker"
assert_eq "your directory still exists" "yes" "$( [ -d "$WORK" ] && echo yes || echo no )"

section "rm needs no flags and no confirmation"
out="$(boxy rm scratch2 2>&1)"
assert_contains "reports where the files went" "workdir left for the OS" "$out"
assert_empty "gone without prompting" "$(docker ps -aq -f name='^scratch2$')"

section "name-omission counts boxes, not sidecars"
# A --net limited box brings a proxy container that also carries
# boxy.managed=1. Counting it made "the name may be omitted when exactly one
# box exists" false for every limited box.
purge_all
boxy create -n onlybox --net limited >/dev/null 2>&1
assert_eq "two managed containers exist" "2" \
    "$(docker ps -aq --filter 'label=boxy.managed=1' | grep -c .)"
assert_contains "but the name is still optional" "onlybox" "$(boxy info 2>&1)"
boxy rm onlybox >/dev/null 2>&1

section "messages when the name cannot be inferred"
assert_contains "no boxes at all" "no boxes exist" "$(boxy info 2>&1)"
boxy create -n one >/dev/null 2>&1
boxy create -n two >/dev/null 2>&1
assert_contains "several boxes: names them" "one" "$(boxy info 2>&1)"
purge_all

section "boxy env reaches every way into the box"
# The sharp case is `ssh box cmd`: it reads no profile and no rc of its own.
# It works because bash sources ~/.bashrc when sshd started it, and boxy's
# block at the top of .bashrc — above Debian's non-interactive guard — sources
# the loader.
boxy create -n envb >/dev/null 2>&1
boxy env envb API_KEY=secret123 REGION=us-east-1 >/dev/null 2>&1
assert_eq "non-interactive ssh sees it" "secret123" "$(bssh envb 'echo $API_KEY')"
assert_eq "a login shell sees it"       "secret123" \
    "$(bssh envb 'bash -lc "echo \$API_KEY"')"
assert_eq "boxy exec sees it too"       "secret123" "$(boxy exec envb 'echo $API_KEY')"
assert_contains "and it lists" "REGION=us-east-1" "$(boxy env envb)"
# The block has to be above the guard or the non-interactive case returns
# before reaching it.
assert_contains "the loader is sourced from the boxy block" "boxy-env.sh" \
    "$(docker exec envb head -4 /home/boxyboy/.bashrc)"

section "env survives a restart with no host state"
# Nothing is replayed on start: the file lives in the container, and the
# container filesystem survives a restart untouched.
boxy stop envb >/dev/null 2>&1; boxy start envb >/dev/null 2>&1
assert_eq "still set after stop/start" "secret123" "$(bssh envb 'echo $API_KEY')"
assert_empty "and boxy keeps no host-side copy" \
    "$(ls "$BOXY_STATE_DIR/instances/envb/env" 2>/dev/null)"

section "env rewrites rather than appends"
boxy env envb API_KEY=rotated >/dev/null 2>&1
assert_eq "the new value wins" "rotated" "$(bssh envb 'echo $API_KEY')"
assert_eq "and the key appears once" "1" \
    "$(docker exec envb grep -c '^API_KEY=' /etc/boxy-env)"
boxy env envb --unset REGION >/dev/null 2>&1
assert_empty "unset clears it" "$(bssh envb 'echo $REGION')"

section "env values need no quoting"
# The data file is plain KEY=VALUE and the loader uses `export "$line"`, which
# passes the whole assignment as one argument. Nothing re-parses a value as
# shell, so these are all literals.
boxy env envb 'SPACED=two words' "QUOTED=it's quoted" 'DOLLAR=$notexpanded' >/dev/null 2>&1
assert_eq "spaces via ssh"  "two words"     "$(bssh envb 'echo $SPACED')"
assert_eq "quote via ssh"   "it's quoted"   "$(bssh envb 'echo $QUOTED')"
assert_eq "quote via exec"  "it's quoted"   "$(boxy exec envb 'echo $QUOTED')"
assert_eq "no expansion"    '$notexpanded'  "$(boxy exec envb 'echo $DOLLAR')"

section "a live session can pick up a change"
# pam_env and the rc files run once, at session start. Nothing outside a shell
# can alter its environment, so a refresh is the session sourcing the loader.
boxy env envb LIVE=yes >/dev/null 2>&1
assert_eq "sourcing the loader applies it" "yes" \
    "$(bssh envb 'unset LIVE; . /etc/profile.d/boxy-env.sh; echo $LIVE')"

section "env refuses names that belong to boxy"
assert_contains "PATH is refused" "belong to boxy" "$(boxy env envb PATH=/evil 2>&1)"
assert_eq "and PATH is intact" "/opt/conda/bin" "$(bssh envb 'echo ${PATH%%:*}')"
assert_contains "BOXY_* is refused" "belong to boxy" \
    "$(boxy env envb BOXY_PASSWORD_HASH=x 2>&1)"
assert_eq "the sudo hash never lands in the file" "0" \
    "$(docker exec envb sh -c 'grep -c BOXY_PASSWORD_HASH /etc/boxy-env || true')"
assert_contains "a non-identifier is refused" "must be identifiers" \
    "$(boxy env envb 9bad=x 2>&1)"
purge_all

section "/etc/environment is rewritten, not truncated"
# The entrypoint runs on every start. It used to write the file with `>`, which
# was idempotent but silently discarded anything you had put there by hand the
# first time the box came back.
boxy create -n envkeep >/dev/null 2>&1
docker exec -u root envkeep sh -c "printf 'MY_OWN=survives\n' >> /etc/environment"
boxy stop envkeep >/dev/null 2>&1; boxy start envkeep >/dev/null 2>&1
assert_eq "a hand-added line survives a restart" "survives" \
    "$(bssh envkeep 'echo $MY_OWN')"
assert_eq "and boxy's own block is still applied" "envkeep" \
    "$(bssh envkeep 'echo $BOXY_NAME')"
assert_eq "with exactly one boxy block" "1" \
    "$(docker exec envkeep grep -c '>>> boxy >>>' /etc/environment)"
# A key set on both sides would leave pam_env to choose; boxy's has to win.
docker exec -u root envkeep sh -c "printf 'PATH=/hijacked\n' >> /etc/environment"
boxy stop envkeep >/dev/null 2>&1; boxy start envkeep >/dev/null 2>&1
assert_eq "a conflicting key appears once" "1" \
    "$(docker exec envkeep grep -c '^PATH=' /etc/environment)"
assert_eq "and boxy's value is the one in force" "/opt/conda/bin" \
    "$(bssh envkeep 'echo ${PATH%%:*}')"
assert_eq "unrelated hand edits are still kept" "survives" \
    "$(bssh envkeep 'echo $MY_OWN')"
boxy rm envkeep >/dev/null 2>&1

section "config --init installs a config you point it at"
# The argument is the SOURCE; the destination is always the path boxy reads.
# Writing to an arbitrary destination would produce a file boxy ignores.
# The old failure mode was worse still: the positional was dropped entirely,
# so --init wrote the default path and reported success naming neither.
CFG="$TEST_TMP/cfg"
rm -rf "$CFG"; mkdir -p "$CFG"
printf '# template\nBOXY_USER=teamuser\n' > "$CFG/team.conf"
out="$(BOXY_CONFIG_DIR="$CFG/active" boxy config --init "$CFG/team.conf" 2>&1)"
assert_eq "it lands in the config dir" "yes" \
    "$( [ -f "$CFG/active/config" ] && echo yes || echo no )"
assert_contains "and names where it went" "$CFG/active/config" "$out"
assert_contains "and where it came from" "$CFG/team.conf" "$out"
# The point of installing to the active path: no extra step to make it count.
assert_contains "the imported settings are immediately in effect" "teamuser" \
    "$(BOXY_CONFIG_DIR="$CFG/active" boxy config)"
# One directory holds both, so they can never come apart.
assert_eq "the allowlist lands beside it" "yes" \
    "$( [ -f "$CFG/active/allowlist.txt" ] && echo yes || echo no )"
assert_eq "no source means the bundled example" "same" \
    "$(BOXY_CONFIG_DIR="$CFG/plain" boxy config --init >/dev/null 2>&1; \
       diff -q "$CFG/plain/config" ./boxy.conf.example >/dev/null && echo same || echo differs)"

section "config --init never overwrites, and says what is in the way"
# Deleting is the caller's to do, so every file blocking the install is named.
out="$(BOXY_CONFIG_DIR="$CFG/active" boxy config --init 2>&1)"
assert_contains "it refuses"                "nothing written"        "$out"
assert_contains "naming the config"         "$CFG/active/config"     "$out"
assert_contains "and the allowlist too"     "$CFG/active/allowlist.txt" "$out"
assert_contains "the imported config is untouched" "teamuser" \
    "$(BOXY_CONFIG_DIR="$CFG/active" boxy config)"

section "BOXY_CONFIG_DIR cannot be set from inside the config"
# Circular: by the time the file is read, the directory has already been used
# to find it. Left alone it would half-apply — config from the old directory,
# allowlist from the new one.
mkdir -p "$CFG/circ"
printf 'BOXY_CONFIG_DIR=/somewhere/else\nBOXY_USER=stillread\n' > "$CFG/circ/config"
out="$(BOXY_CONFIG_DIR="$CFG/circ" boxy config 2>&1)"
assert_contains "it warns"                "ignoring BOXY_CONFIG_DIR" "$out"
assert_contains "the rest of the file still applies" "stillread"   "$out"
assert_contains "and the allowlist stays with the real dir" "$CFG/circ/allowlist.txt" "$out"

section "config rejects what it cannot act on"
assert_contains "a missing source" "no such file" \
    "$(BOXY_CONFIG_DIR="$CFG/x" boxy config --init "$CFG/nope.conf" 2>&1)"
assert_empty "and creates no destination when the source is bad" \
    "$(ls "$CFG/x/config" 2>/dev/null)"
assert_contains "unknown option" "unknown option" "$(boxy config --bogus 2>&1)"
assert_contains "stray argument without --init" "unexpected argument" \
    "$(boxy config stray 2>&1)"
assert_contains "two sources" "one source at a time" \
    "$(BOXY_CONFIG_DIR="$CFG/y" boxy config --init a.conf b.conf 2>&1)"
assert_contains "--help is help, not the settings dump" "usage: boxy config" \
    "$(boxy config --help 2>&1)"
rm -rf "$CFG"

section "create validates before doing work"
assert_contains "a bad path is caught up front" "not a directory" \
    "$(boxy create /nope/nothing 2>&1)"
assert_empty "and no keypair or state was created for it" \
    "$(ls "$BOXY_STATE_DIR/instances" 2>/dev/null)"

section "orphaned state is reported and reclaimed"
boxy create -n orphan >/dev/null 2>&1
docker rm -f orphan >/dev/null 2>&1          # removed behind boxy's back
assert_contains "doctor notices it" "orphaned state" "$(boxy doctor 2>&1)"
boxy create -n fresh >/dev/null 2>&1
assert_empty "the next create reclaims it" \
    "$(ls -d "$BOXY_STATE_DIR/instances/orphan" 2>/dev/null)"
purge_all

purge_all
report "workflow"
