#!/usr/bin/env bash
# /opt/firellm/agent-run  -- the thing that runs inside the VM
set -euo pipefail

echo "[firellm-guest] agent-run starting at $(date)"
echo "[firellm-guest] cwd: $(pwd)"
echo "[firellm-guest] kernel: $(uname -a)"
echo "[firellm-guest] work dir contents:"
ls -la /work 2>/dev/null || echo "(no /work yet)"

TASK=""
if [[ -f /work/.firellm-task ]]; then
	TASK=$(cat /work/.firellm-task)
fi
TASK=${TASK:-${FIRELLM_TASK:-}}

if [[ -n "$TASK" ]]; then
	echo "[firellm-guest] TASK: $TASK"
	cd /work 2>/dev/null || true
	# TODO: plug your agent here, e.g.
	#   if command -v opencode >/dev/null; then
	#       opencode --non-interactive --task "$TASK" || true
	#   fi
	echo "[firellm-guest] (placeholder - add your agent invocation above)"
	echo "$TASK" >/work/.firellm-task.done 2>/dev/null || true
fi

# keep the VM alive for inspection / further work. Use `poweroff` from inside when finished.
exec /bin/bash --login
