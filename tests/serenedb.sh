#!/usr/bin/env bash
# The whole thing, against a real database.
#
# Run on demand rather than in the suite: it wants a few gigabytes, a 4G VM and
# a couple of minutes. What it proves is the arrangement everything else exists
# for - a server running inside a VM, and a dashboard on the *host* able to see
# all three of the things it needs to see:
#
#   SQL      over TCP into the VM
#   /proc    the guest's, mounted here, because a dashboard reading this
#            machine's /proc would describe this machine
#   perf     captured inside, read out here, resolvable against any build with
#            a matching build-id
#
#   tests/serenedb.sh [image]      default: serenedb/serenedb:26.07.5
#
# shellcheck disable=SC2016  # single quotes are deliberate: these run in the guest
# shellcheck disable=SC2329  # cleanup runs from a trap
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
FIRECODE="$ROOT/bin/firecode"
VENV="$ROOT/.venv/bin/python"
IMAGE=${1:-serenedb/serenedb:26.07.5}
LAB=$(mktemp -d /tmp/serenedb-lab.XXXXXX)
MNT=$(mktemp -d /tmp/serenedb-proc.XXXXXX)
PULLED=$(mktemp -d /tmp/serenedb-perf.XXXXXX)
PASS=0
FAIL=0
KEEP=${KEEP:-0}
FUSE_PID=""

ok() {
	PASS=$((PASS + 1))
	printf '  \033[32mok\033[0m    %s\n' "$1"
}
no() {
	FAIL=$((FAIL + 1))
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	[[ -n ${2:-} ]] && printf '        %s\n' "$2"
}

cleanup() {
	[[ -n $FUSE_PID ]] && { fusermount -u "$MNT" 2>/dev/null || kill "$FUSE_PID" 2>/dev/null; }
	if ((KEEP)); then
		echo
		echo "  the VM is still up, on purpose (KEEP=1):"
		echo "    cd $LAB && $FIRECODE enter          a shell inside it"
		echo "    cd $LAB && $FIRECODE down           when you are done"
	else
		(cd "$LAB" && "$FIRECODE" down >/dev/null 2>&1)
		rm -rf "$LAB" "$MNT" "$PULLED"
	fi
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
	echo "needs docker"
	exit 2
}
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
	echo "no such image locally: $IMAGE"
	exit 2
}

echo "serenedb end to end  ($IMAGE)"
echo
git -C "$LAB" init -q 2>/dev/null
echo "lab" >"$LAB/README.md"

echo "the image as a layer"
if "$FIRECODE" layer add "$IMAGE" --project "$LAB" >/dev/null 2>&1; then
	ok "imported, keyed by digest"
else
	no "imported, keyed by digest"
	exit 1
fi

echo
echo "a VM with the database in it"
if (cd "$LAB" && timeout 900 "$FIRECODE" up --mem 4096 >/dev/null 2>&1); then
	ok "the VM is up"
else
	no "the VM is up"
	exit 1
fi

# Started the way its own image starts it, so this tests the real thing and
# not a reconstruction of it.
(cd "$LAB" && "$FIRECODE" in 'sudo mkdir -p /var/lib/serenedb && sudo chown $(id -u):$(id -g) /var/lib/serenedb
export POSTGRES_PASSWORD=lab PGDATA=/var/lib/serenedb
setsid nohup /entrypoint.sh serened > /tmp/serened.log 2>&1 &
sleep 25; pgrep -x serened >/dev/null' >/dev/null 2>&1)

GUEST=$( (cd "$LAB" && "$FIRECODE" in "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null) | tr -cd '0-9.')
SPID=$( (cd "$LAB" && "$FIRECODE" in 'pgrep -x serened | head -1' 2>/dev/null) | tr -cd '0-9')
if [[ -n $SPID ]]; then
	ok "serened is running (pid $SPID in the VM, on $GUEST)"
else
	no "serened is running" "$( (cd "$LAB" && "$FIRECODE" in 'tail -3 /tmp/serened.log' 2>&1))"
	exit 1
fi

echo
echo "SQL, from this host into the VM"
if [[ -x $VENV ]] && "$VENV" -c "import psycopg" 2>/dev/null; then
	VER=$("$VENV" -c "
import psycopg
c = psycopg.connect(host='$GUEST', port=7890, user='postgres', password='lab',
                    dbname='postgres', connect_timeout=20, autocommit=True)
c.execute('drop table if exists bench')
c.execute('create table bench (id bigint, payload text)')
with c.cursor().copy('copy bench (id, payload) from stdin') as cp:
    for i in range(400000):
        cp.write_row((i, 'row-%d-padding-padding-padding' % i))
print(c.execute('select version()').fetchone()[0][:40], c.execute('select count(*) from bench').fetchone()[0])
" 2>&1 | tail -1)
	if [[ $VER == *400000* ]]; then
		ok "connected and loaded 400k rows ($VER)"
	else
		no "connected and loaded 400k rows" "$VER"
	fi
else
	no "connected and loaded 400k rows" "no psycopg in $ROOT/.venv"
fi

echo
echo "the guest's /proc, on this host"
JAIL=$( (cd "$LAB" && "$FIRECODE" list --ids 2>/dev/null | awk -v p="$LAB" '$2==p{print $1}' | head -1))
JAIL=$(cat "$ROOT/runs/$JAIL/jail" 2>/dev/null)
if [[ -x $VENV ]] && "$VENV" -c "import fuse" 2>/dev/null && [[ -S $JAIL/firecracker-vsock.sock ]]; then
	"$VENV" "$ROOT/scripts/vmprocfs.py" "$JAIL/firecracker-vsock.sock" 1026 "$MNT" --ttl 2 \
		>/tmp/serenedb-vmprocfs.log 2>&1 &
	FUSE_PID=$!
	for _ in $(seq 40); do
		mountpoint -q "$MNT" && break
		sleep 0.25
	done
	THREADS=$(timeout 40 ls "$MNT/$SPID/task" 2>/dev/null | wc -l)
	RSS=$(timeout 30 awk '/VmRSS/{print $2}' "$MNT/$SPID/status" 2>/dev/null)
	if ((THREADS > 1)) && [[ -n $RSS ]]; then
		ok "serened's live state is readable here ($THREADS threads, ${RSS} kB resident)"
	else
		no "serened's live state is readable here" "threads=$THREADS rss=$RSS"
	fi
	GM=$(timeout 20 awk '/MemTotal/{print $2}' "$MNT/meminfo" 2>/dev/null)
	HM=$(awk '/MemTotal/{print $2}' /proc/meminfo)
	if [[ -n $GM && $GM != "$HM" ]]; then
		ok "and it is the guest's kernel, not this one's ($GM vs $HM kB)"
	else
		no "and it is the guest's kernel, not this one's" "$GM vs $HM"
	fi
else
	no "serened's live state is readable here" "no fusepy in $ROOT/.venv"
fi

echo
echo "profiling it"
# perf is not packaged for a custom kernel version, so a released one is
# pointed at it. Software events do not care; hardware counters are absent
# either way, there being no virtual PMU.
PERF_SETUP='command -v perf >/dev/null 2>&1 && exit 0
# A fresh VM has no package index, so a search before this finds nothing and
# the install below quietly gets no version to install.
sudo apt-get update -qq >/dev/null 2>&1
PKG=$(apt-cache search "^linux-tools-6\.8\.0-[0-9]+-generic$" | cut -d" " -f1 | sort -V | tail -1)
[ -n "$PKG" ] || { echo "no linux-tools package available" >&2; exit 1; }
sudo apt-get install -y -qq linux-tools-common "$PKG" >/dev/null 2>&1
BIN=$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | head -1)
[ -n "$BIN" ] || { echo "installed $PKG but found no perf binary" >&2; exit 1; }
# The wrapper looks for a perf matching `uname -r`, and there is no package for
# a kernel built here. A released one records software events perfectly well.
sudo mkdir -p "/usr/lib/linux-tools/$(uname -r)"
sudo ln -sf "$BIN" "/usr/lib/linux-tools/$(uname -r)/perf"
perf --version'
PERF_OUT=$( (cd "$LAB" && timeout 900 "$FIRECODE" in "$PERF_SETUP" 2>&1))
if printf '%s' "$PERF_OUT" | grep -q "perf version"; then
	ok "perf is available in the VM ($(printf '%s' "$PERF_OUT" | grep -o 'perf version [0-9.]*'))"
else
	no "perf is available in the VM" "$(printf '%s' "$PERF_OUT" | tail -2)"
fi

if [[ -x $VENV ]]; then
	("$VENV" -c "
import psycopg
c = psycopg.connect(host='$GUEST', port=7890, user='postgres', password='lab',
                    dbname='postgres', connect_timeout=20, autocommit=True)
for _ in range(2000):
    c.execute('select count(*), sum(length(payload)), avg(id) from bench where payload like %s', ('%padding%',))
" >/dev/null 2>&1) &
	LOAD=$!
	sleep 2
fi
RECORD='PID=$(pgrep -x serened | head -1)
sudo perf record -F 299 -g -e cpu-clock -p "$PID" -o /tmp/serened.perf.data -- sleep 20 2>&1 | tail -2
sudo chown $(id -u):$(id -g) /tmp/serened.perf.data'
REC_OUT=$( (cd "$LAB" && timeout 600 "$FIRECODE" in "$RECORD" 2>&1))
SAMPLES=$(printf '%s' "$REC_OUT" | grep -oE '[0-9]+ samples' | head -1)
kill "${LOAD:-0}" 2>/dev/null
if [[ -n $SAMPLES ]]; then
	ok "captured a profile of it under load ($SAMPLES)"
else
	no "captured a profile of it under load"
fi

if (cd "$LAB" && "$FIRECODE" mirror --once --out "$PULLED" '/tmp/serened.perf.data' >/dev/null 2>&1); then
	ok "the capture is readable on this host"
else
	no "the capture is readable on this host"
fi

BUILDID=$(perf buildid-list -i "$PULLED/tmp/serened.perf.data" 2>/dev/null |
	awk '/serened/{print $1}' | head -1)
if [[ -n $BUILDID ]]; then
	ok "and names the build it needs: ${BUILDID:0:16}..."
else
	no "and names the build it needs"
fi

# The one thing that does not work, stated rather than skipped: a stripped
# binary profiles fine and resolves to nothing. A build with the build-id
# above, in serenedash's symbol_paths, is what turns these into names - and it
# does not have to be the machine the server ran on, only the same build.
NAMED=$( (cd "$LAB" && "$FIRECODE" in 'perf report -i /tmp/serened.perf.data --stdio --sort symbol -g none 2>/dev/null | grep -cE "\[\.\] [a-zA-Z_]"' 2>/dev/null) | tr -cd '0-9')
if [[ ${NAMED:-0} -gt 0 ]]; then
	ok "the profile has symbol names ($NAMED)"
else
	printf '  \033[33mknown\033[0m %s\n' \
		"the profile has addresses, not names - this image's serened is stripped"
	printf '        %s\n' "a build with build-id ${BUILDID:0:16} resolves it, on any machine"
fi

echo
if ((FAIL == 0)); then
	printf '\033[32m%d passed\033[0m\n' "$PASS"
	exit 0
fi
printf '\033[31m%d failed\033[0m, %d passed\n' "$FAIL" "$PASS"
exit 1
