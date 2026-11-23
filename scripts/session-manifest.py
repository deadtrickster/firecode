#!/usr/bin/env python3
"""One JSON file per state session: who it belongs to, what it was for, and
whether its work has been copied out.

bin/firecode owns the state directory; this program owns the shape of the file
in it, so the writer and the reader cannot drift. Every write is a temp file
and a rename, so a reader never sees half a manifest and a caller may set the
same field twice.

  session-manifest.py set FILE K=V...      merge fields (empty V means null)
  session-manifest.py get FILE KEY         one value, or nothing
  session-manifest.py add-run FILE RUN     record a run id, newest 10 kept
  session-manifest.py extracted FILE [--tip SHA] [--bundle PATH] [--verified]
  session-manifest.py pool FILE [--project P] [--state S] [--snapshot D]
                                  [--bytes N] [--clear]
  session-manifest.py report DIR [--json]  every session, with what is on disk

`report` reads one line per session from stdin:

  NAME<TAB>BYTES<TAB>MTIME_EPOCH<TAB>FILES

and prints the table or the JSON object that `firecode state ls` answers with.
A session with no manifest is `unknown`, not absent: the whole point is that
state from before this existed is still listed and still reclaimable.
"""

import calendar
import json
import os
import sys
import time

PURPOSES = ("session", "reviewer", "ephemeral", "test")
POOL_STATES = ("running", "sleeping", "in-use")
RUNS_KEPT = 10


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def set_key(data, key, value):
    parts = key.split(".")
    node = data
    for p in parts[:-1]:
        nxt = node.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            node[p] = nxt
        node = nxt
    node[parts[-1]] = value


def get_key(data, key):
    node = data
    for p in key.split("."):
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node


def cmd_set(path, pairs):
    data = load(path)
    for pair in pairs:
        if "=" not in pair:
            sys.exit("set: expected KEY=VALUE, got %r" % pair)
        key, value = pair.split("=", 1)
        set_key(data, key, value if value != "" else None)
    if "created" not in data:
        data["created"] = now()
    save(path, data)


def cmd_unset(path, keys):
    data = load(path)
    for key in keys:
        parts = key.split(".")
        node = data
        for p in parts[:-1]:
            node = node.get(p) if isinstance(node, dict) else None
            if not isinstance(node, dict):
                node = None
                break
        if isinstance(node, dict):
            node.pop(parts[-1], None)
    save(path, data)


def cmd_add_run(path, run):
    data = load(path)
    runs = [r for r in data.get("runs") or [] if r != run]
    runs.append(run)
    data["runs"] = runs[-RUNS_KEPT:]
    data.setdefault("created", now())
    data["last_used"] = now()
    save(path, data)


def cmd_extracted(path, tip=None, bundle=None, verified=False, nothing=False):
    data = load(path)
    mark = {
        "at": now(),
        "tip": tip or None,
        "bundle": bundle or None,
        "verified": bool(verified),
    }
    if nothing:
        # A run that committed nothing - no repository, or no commits - has
        # work that is out the moment its directory is. Saying so is what lets
        # its state be reclaimed; leaving it null would pin 3G forever.
        mark["nothing"] = True
    data["extracted"] = mark
    save(path, data)


def cmd_pool(path, project=None, state=None, snapshot=None, nbytes=None,
             clear=False):
    data = load(path)
    if clear:
        data.pop("pool", None)
        save(path, data)
        return
    pool = data.get("pool") or {}
    if project is not None:
        pool["project"] = project
    if state is not None:
        if state not in POOL_STATES:
            sys.exit("pool: state is one of %s" % ", ".join(POOL_STATES))
        pool["state"] = state
    if snapshot is not None:
        pool["snapshot"] = snapshot or None
    if nbytes is not None:
        pool["snapshot_bytes"] = int(nbytes)
    pool["last_used"] = now()
    data["pool"] = pool
    save(path, data)


def epoch_of(stamp):
    if not stamp:
        return 0
    try:
        return int(calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")))
    except (ValueError, TypeError):
        return 0


def row_for(name, data, nbytes, mtime, files):
    extracted = data.get("extracted")
    out = {
        "name": name,
        "manifest": bool(data),
        "owner": data.get("owner"),
        "owner_project": data.get("owner_project"),
        "purpose": data.get("purpose") or "unknown",
        "worktree": data.get("worktree"),
        "branch": data.get("branch"),
        "created": data.get("created"),
        "last_used": data.get("last_used"),
        "runs": data.get("runs") or [],
        "extracted": extracted if isinstance(extracted, dict) else None,
        "pool": data.get("pool") if isinstance(data.get("pool"), dict) else None,
        "bytes": nbytes,
        "files": files,
    }
    if out["purpose"] not in PURPOSES:
        out["purpose"] = "unknown"
    stamped = out["last_used"]
    if not stamped:
        out["last_used"] = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                         time.gmtime(mtime or 0))
        out["last_used_source"] = "mtime"
    else:
        out["last_used_source"] = "manifest"
    out["last_used_epoch"] = epoch_of(out["last_used"]) or int(mtime or 0)
    # What a reaper may do with it. "out" means the manifest says the work was
    # copied out; "in" means it says it was never; "unknown" is state from
    # before manifests, which is reclaimable on age but never called safe.
    if isinstance(extracted, dict):
        out["work"] = "out"
    elif not out["manifest"]:
        out["work"] = "unknown"
    elif out["runs"]:
        out["work"] = "in"
    else:
        # A manifest written by a run that never got as far as starting: its
        # drives are empty, so there is nothing to lose by reclaiming them.
        out["work"] = "nothing"
    # Unextracted work is never deleted automatically, and a session old enough
    # to be worth telling somebody about is flagged rather than quietly kept.
    if out["work"] == "in":
        days = (time.time() - out["last_used_epoch"]) / 86400.0
        out["unextracted_days"] = round(days, 1)
        out["flagged"] = days >= 3
    else:
        out["unextracted_days"] = None
        out["flagged"] = False
    return out


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d%s" % (n, unit)) if unit == "B" else ("%.1f%s" % (n, unit))
        n /= 1024.0


def cmd_report(state_dir, as_json, rows, as_tsv=False):
    sessions = []
    for line in rows:
        line = line.rstrip("\n")
        if not line:
            continue
        name, nbytes, mtime, files = line.split("\t")
        path = os.path.join(state_dir, name + ".json")
        sessions.append(row_for(name, load(path), int(nbytes), int(mtime),
                                int(files)))
    sessions.sort(key=lambda s: s["name"])
    if as_tsv:
        # The reapers' input: one line a session, in a shape bash can read
        # without a fork per field. Two reapers and `state ls` read the same
        # facts from here, so no two of them can disagree about an age.
        for s in sessions:
            pool = s["pool"] or {}
            print("\t".join([
                s["name"], str(s["bytes"]), str(s["files"]),
                s["purpose"], s["work"], str(s["last_used_epoch"]),
                "1" if s["manifest"] else "0",
                pool.get("state") or "-",
                pool.get("project") or "-",
            ]))
        return
    if as_json:
        json.dump({"sessions": sessions}, sys.stdout, indent=1, sort_keys=True)
        sys.stdout.write("\n")
        return

    def cell(value, width):
        text = "-" if value in (None, "") else str(value)
        return text if len(text) <= width else text[: width - 1] + "~"

    head = ("NAME", "OWNER", "PURPOSE", "SIZE", "LAST USED", "EXTRACTED")
    table = [head]
    total = 0
    for s in sessions:
        total += s["bytes"]
        ex = s["extracted"]
        if ex is None:
            mark = "unknown" if not s["manifest"] else "NOT OUT"
        elif ex.get("tip"):
            mark = "yes " + str(ex["tip"])[:8]
        else:
            mark = "yes (no commits)"
        pool = s["pool"]
        purpose = s["purpose"]
        if pool and pool.get("state"):
            purpose = "%s/%s" % (purpose, pool["state"])
        table.append((
            s["name"], (s["owner"] or "-"), purpose, human(s["bytes"]),
            (s["last_used"] or "-").replace("T", " ").rstrip("Z"),
            mark,
        ))
    widths = [max(len(row[i]) for row in table) for i in range(len(head))]
    for row in table:
        print("  ".join(c.ljust(widths[i]) if i < 3 else c
                        for i, c in enumerate(row)).rstrip())
    print("\n  %d session(s), %s actual in %s"
          % (len(sessions), human(total), state_dir))
    unknown = sum(1 for s in sessions if not s["manifest"])
    if unknown:
        print("  %d of them have no manifest: owner, purpose and extraction "
              "are unknown" % unknown)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__.strip().splitlines()[0])
    cmd, rest = argv[1], argv[2:]
    if cmd == "set":
        cmd_set(rest[0], rest[1:])
    elif cmd == "unset":
        cmd_unset(rest[0], rest[1:])
    elif cmd == "get":
        value = get_key(load(rest[0]), rest[1])
        if value is not None:
            print(value if isinstance(value, str) else json.dumps(value))
    elif cmd == "add-run":
        cmd_add_run(rest[0], rest[1])
    elif cmd == "extracted":
        opts = dict(tip=None, bundle=None, verified=False, nothing=False)
        it = iter(rest[1:])
        for a in it:
            if a == "--tip":
                opts["tip"] = next(it)
            elif a == "--bundle":
                opts["bundle"] = next(it)
            elif a == "--verified":
                opts["verified"] = True
            elif a == "--nothing":
                opts["nothing"] = True
            else:
                sys.exit("extracted: unknown option %r" % a)
        cmd_extracted(rest[0], **opts)
    elif cmd == "pool":
        opts = dict(project=None, state=None, snapshot=None, nbytes=None,
                    clear=False)
        it = iter(rest[1:])
        for a in it:
            if a == "--project":
                opts["project"] = next(it)
            elif a == "--state":
                opts["state"] = next(it)
            elif a == "--snapshot":
                opts["snapshot"] = next(it)
            elif a == "--bytes":
                opts["nbytes"] = next(it)
            elif a == "--clear":
                opts["clear"] = True
            else:
                sys.exit("pool: unknown option %r" % a)
        cmd_pool(rest[0], **opts)
    elif cmd == "report":
        as_json = "--json" in rest
        as_tsv = "--tsv" in rest
        cmd_report(rest[0], as_json, sys.stdin, as_tsv)
    else:
        sys.exit("unknown command: %s" % cmd)


if __name__ == "__main__":
    main(sys.argv)
