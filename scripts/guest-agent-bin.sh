#!/usr/bin/env bash
# guest-agent-bin.sh - the agent binary a guest runs, when the host's cannot.
#
#   guest-agent-bin.sh claude|opencode <host-binary>
#
# Prints the path of a linux-arm64 build of the same version as the host's,
# fetched once and cached under vendor/guest/. On Linux the guest runs the
# host's binary as it is; on a Mac the host's is Mach-O, and the guest is
# arm64 Linux. Same version, so the guest still runs what you run.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
CACHE="$ROOT/vendor/guest"
agent=${1:?usage: guest-agent-bin.sh claude|opencode <host-binary>}
host=${2:?}

die() {
	echo "guest-agent-bin: $*" >&2
	exit 1
}

version=$("$host" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ||
	true
[[ -n $version ]] || die "could not tell which version $host is"

out="$CACHE/$agent-$version-linux-arm64"
if [[ -x $out ]]; then
	echo "$out"
	exit 0
fi
mkdir -p "$CACHE"
tmp=$(mktemp "$CACHE/.$agent.XXXXXX")
trap 'rm -f "$tmp" "$tmp.tgz"' EXIT

case $agent in
claude)
	base=https://downloads.claude.ai/claude-code-releases/$version
	want=$(curl -fsSL "$base/manifest.json" |
		python3 -c 'import json, sys; print(json.load(sys.stdin)["platforms"]["linux-arm64"]["checksum"])') ||
		die "no linux-arm64 build of claude $version in its manifest"
	curl -fsSL -o "$tmp" "$base/linux-arm64/claude" || die "could not fetch claude $version"
	[[ $(sha256sum "$tmp" | cut -d' ' -f1) == "$want" ]] ||
		die "claude $version for linux-arm64 does not match its manifest checksum"
	;;
opencode)
	url=https://github.com/sst/opencode/releases/download/v$version/opencode-linux-arm64.tar.gz
	curl -fsSL -o "$tmp.tgz" "$url" || die "could not fetch opencode $version"
	tar -xzOf "$tmp.tgz" opencode >"$tmp" || die "no opencode binary in $url"
	;;
*) die "unknown agent $agent" ;;
esac

chmod 0755 "$tmp"
mv -f "$tmp" "$out"
echo "$out"
