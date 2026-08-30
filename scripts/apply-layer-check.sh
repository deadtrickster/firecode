#!/usr/bin/env bash
#
# DOES A FAILED LAYER LEAVE A STAMP SAYING IT SUCCEEDED?
#
# That is the one defect in this design that would be invisible. A layer whose
# third line failed but whose stamp says "current" is never retried: the next
# boot trusts it, the package is missing, and the failure turns up somewhere
# else entirely as a check that reds for reasons of its own. Everything else
# apply-layer does announces itself.
#
# It runs against a STUB GUEST rather than a VM - FIRECODE_BIN and
# FIRECODE_LAYER_STAMP point at a temp directory this owns - so the arms below
# are about the script's stamp discipline, which is where the risk is, and not
# about whether a VM happened to be up.
#
# FOUR ARMS, and the third is the one this exists for:
#
#   a clean layer applies and leaves a stamp
#   applying it again does nothing at all
#   a layer whose second line FAILS leaves the stamp untouched
#   a project with no firecode.layer says so rather than passing silently
set -euo pipefail

self=$(readlink -f "$0")
apply=$(dirname "$self")/apply-layer.sh
[ -x "$apply" ] || {
	printf 'apply-layer-check: no apply-layer.sh beside me\n' >&2
	exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/project" "$work/guest"

# The stub speaks the shape apply-layer calls: `<bin> in VM bash -lc CMD`, and
# runs the command here instead of in a guest. RAN records what reached it, so
# an arm can assert what was ATTEMPTED and not only what came back.
#
# A FAKE sudo ON PATH, rather than stripping the word out of the command. The
# apply uses sudo twice and in two shapes - `sudo -n bash -c '...'` for a RUN
# line and `| sudo -n tee` for the stamp - and a stub that pattern-matched the
# first ran the real sudo for the second, which asks for a password nobody can
# type and fails every arm for a reason that has nothing to do with the code
# under test.
mkdir -p "$work/bin"
cat >"$work/bin/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
while [ "${1:-}" = "-n" ] || [ "${1:-}" = "-E" ]; do shift; done
exec "$@"
FAKESUDO
chmod +x "$work/bin/sudo"

cat >"$work/fc" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
shift 2               # `in VM`
shift 2               # `bash -lc`
printf '%s\n' "${1:-}" >>"$FAKE_RAN"
PATH="$FAKE_BIN:$PATH" bash -lc "${1:-}"
STUB
chmod +x "$work/fc"

export FIRECODE_BIN="$work/fc"
export FIRECODE_LAYER_STAMP="$work/guest/stamp"
export FAKE_RAN="$work/ran"
export FAKE_BIN="$work/bin"
: >"$FAKE_RAN"

fails=0
say() {
	printf '%s\n' "$1" >&2
	fails=$((fails + 1))
}

# ARM 4 first, because it needs no layer file.
out=$("$apply" --vm fake --project "$work/project" 2>&1) || say "a project with no layer file exited non-zero: $out"
case $out in
*"declares no layer"*) ;;
*) say "a project with no firecode.layer did not say so: $out" ;;
esac

# ARM 1: a clean layer applies and stamps.
cat >"$work/project/firecode.layer" <<'LAYER'
ENV MARK=one
RUN touch "$WORK_OUT/first"
RUN test "$MARK" = one
LAYER
export WORK_OUT="$work/guest"
out=$("$apply" --vm fake --project "$work/project" 2>&1) || say "a clean layer failed to apply: $out"
[ -f "$work/guest/first" ] || say "the layer's own RUN line did not run - nothing reached the guest"
[ -s "$FIRECODE_LAYER_STAMP" ] || say "a clean apply wrote no stamp, so it would run again on every boot"
stamped=$(cat "$FIRECODE_LAYER_STAMP" 2>/dev/null || true)

# ARM 2: applying it again does nothing.
: >"$FAKE_RAN"
out=$("$apply" --vm fake --project "$work/project" 2>&1) || say "the second apply failed: $out"
case $out in
*"is current"*) ;;
*) say "an unchanged layer did not report itself current: $out" ;;
esac
if grep -q 'touch' "$FAKE_RAN" 2>/dev/null; then
	say "an unchanged layer RAN ITS STEPS AGAIN - the stamp is being written but not read"
fi

# ARM 3: THE ONE THIS EXISTS FOR. A layer whose second line fails must not be
# stamped, so the next run retries it.
cat >"$work/project/firecode.layer" <<'LAYER'
RUN touch "$WORK_OUT/second"
RUN false
RUN touch "$WORK_OUT/never"
LAYER
before=$(cat "$FIRECODE_LAYER_STAMP" 2>/dev/null || true)
set +e
out=$("$apply" --vm fake --project "$work/project" 2>&1)
rc=$?
set -e
after=$(cat "$FIRECODE_LAYER_STAMP" 2>/dev/null || true)
[ "$rc" -ne 0 ] || say "a layer with a failing line exited 0"
[ "$after" = "$before" ] || say "A FAILED LAYER MOVED THE STAMP. The next boot would trust it, skip every step, and the missing package would surface somewhere else entirely."
[ -f "$work/guest/never" ] && say "a line after the failure still ran - the apply does not stop at the first failure"
case $out in
*"NOT written"*) ;;
*) say "the failure does not say the stamp was withheld, so a reader cannot tell it will retry: $out" ;;
esac

[ -n "$stamped" ] || say "arm 1 never produced a stamp to compare against"

if [ "$fails" -gt 0 ]; then
	printf 'apply-layer-check: %s arm(s) failed\n' "$fails" >&2
	exit 1
fi
printf 'a clean layer applies once and is not re-run; a failed one leaves no stamp and says so\n'
