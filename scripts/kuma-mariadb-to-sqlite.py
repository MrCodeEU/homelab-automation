#!/usr/bin/env python3
"""One-time migration of Uptime Kuma history from the embedded MariaDB to SQLite.

Kuma has no built-in migration between database types. The monitors, the
notification, maintenance windows and status pages are rebuilt by
provision-kuma; this carries over what cannot be provisioned:

  heartbeat, stat_minutely, stat_hourly, stat_daily   history and uptime stats
  api_key (the key in use)                            same id and hash, so the
                                                      uk<id>_... value in eyaml
                                                      stays valid

Two steps, so the old Kuma keeps serving until the cutover:

  export   against the RUNNING old container (read only), writes JSON lines
  import   into the new kuma.db, with the NEW Kuma STOPPED (SQLite is in WAL
           mode); monitors are mapped old id -> new id by name

Usage on nuc:
  kuma-mariadb-to-sqlite.py export --container uptime-kuma --out /root/kuma-migration/export
  docker stop <new kuma container>
  kuma-mariadb-to-sqlite.py import --export /root/kuma-migration/export \\
      --db /var/lib/docker/volumes/<new volume>/_data/kuma.db
  docker start <new kuma container>

import refuses to run twice (marker in the setting table) and runs in a single
transaction: it either completes or changes nothing. Standard library only.
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys

SOCKET = "/app/data/run/mariadb.sock"
MARKER = "migratedFromMariaDB"
HISTORY = ["heartbeat", "stat_minutely", "stat_hourly", "stat_daily"]
API_KEY_NAME = "llm-based-health-report"


def maria(container, sql):
    """Run a statement in the old container's MariaDB, return stdout lines."""
    cmd = ["docker", "exec", container, "mariadb", "-uroot", "-S", SOCKET, "kuma", "-N", "-B", "--raw", "-e", sql]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return proc.stdout.splitlines()


def columns(container, table):
    return maria(
        container,
        "select column_name from information_schema.columns "
        f"where table_schema='kuma' and table_name='{table}' order by ordinal_position",
    )


def export_table(container, table, path):
    cols = columns(container, table)
    pairs = ", ".join(f"'{c}', `{c}`" for c in cols)
    # json_object keeps NULLs, tabs and newlines in message text intact.
    lines = maria(container, f"select json_object({pairs}) from `{table}` order by id")
    with open(path, "w") as out:
        for line in lines:
            out.write(line + "\n")
    return len(lines)


def cmd_export(args):
    os.makedirs(args.out, exist_ok=True)
    for table in ["monitor", "api_key"] + HISTORY:
        n = export_table(args.container, table, os.path.join(args.out, f"{table}.jsonl"))
        print(f"exported {table}: {n} rows")


def read_rows(directory, table):
    with open(os.path.join(directory, f"{table}.jsonl")) as f:
        return [json.loads(line) for line in f if line.strip()]


def to_sqlite_value(v):
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return v


def cmd_import(args):
    if not os.path.exists(args.db):
        sys.exit(f"{args.db} does not exist: start the new Kuma once (provisioning creates it), then stop it")
    db = sqlite3.connect(args.db, timeout=5)
    db.execute("pragma foreign_keys=on")

    if db.execute("select 1 from setting where `key`=?", (MARKER,)).fetchone():
        sys.exit("already migrated (marker present in setting); refusing to import twice")

    old_monitors = {m["id"]: m["name"] for m in read_rows(args.export, "monitor")}
    new_by_name = dict(db.execute("select name, id from monitor"))
    id_map = {old: new_by_name[name] for old, name in old_monitors.items() if name in new_by_name}
    dropped = sorted(name for old, name in old_monitors.items() if old not in id_map)
    print(f"monitors: {len(old_monitors)} old, {len(new_by_name)} new, {len(id_map)} mapped by name")
    if dropped:
        print(f"  history of {len(dropped)} monitors without a new counterpart is skipped: {', '.join(dropped)}")
    if not id_map:
        sys.exit("no monitor could be mapped: has provision-kuma run against the new Kuma?")

    summary = {}
    with db:  # one transaction
        for table in HISTORY:
            cols = [r[1] for r in db.execute(f"pragma table_info({table})") if r[1] != "id"]
            sql = f"insert or ignore into {table} ({', '.join(cols)}) values ({', '.join('?' * len(cols))})"
            inserted = skipped = 0
            batch = []
            for row in read_rows(args.export, table):
                new_id = id_map.get(row["monitor_id"])
                if new_id is None:
                    skipped += 1
                    continue
                row["monitor_id"] = new_id
                batch.append([to_sqlite_value(row.get(c)) for c in cols])
            before = db.execute(f"select count(*) from {table}").fetchone()[0]
            db.executemany(sql, batch)
            inserted = db.execute(f"select count(*) from {table}").fetchone()[0] - before
            summary[table] = (inserted, skipped, len(batch) - inserted)
            print(f"{table}: inserted {inserted}, skipped {skipped} (unmapped monitor), ignored {len(batch) - inserted} (duplicate)")

        # The API key keeps its id and hash, so the uk<id>_<secret> value in
        # eyaml stays valid. Only the key in use is carried over.
        keys = [k for k in read_rows(args.export, "api_key") if k["name"] == API_KEY_NAME]
        user_id = db.execute("select min(id) from user").fetchone()[0]
        for k in keys:
            if db.execute("select 1 from api_key where id=?", (k["id"],)).fetchone():
                sys.exit(f"api_key id {k['id']} already exists in the new database")
            db.execute(
                "insert into api_key (id, key, name, user_id, created_date, active, expires) values (?,?,?,?,?,?,?)",
                (k["id"], k["key"], k["name"], user_id, k["created_date"], int(bool(k["active"])), k["expires"]),
            )
            print(f"api_key: carried over id {k['id']} ({k['name']})")
        if keys:
            # Without this /metrics ignores API keys and expects the admin's
            # username/password, so the carried-over key would be rejected.
            db.execute(
                "insert into setting (`key`, value, type) values ('apiKeysEnabled', 'true', null) "
                "on conflict(`key`) do update set value='true'"
            )
        else:
            print(f"api_key: no key named {API_KEY_NAME!r} found, nothing carried over")

        db.execute("insert into setting (`key`, value, type) values (?, ?, ?)", (MARKER, json.dumps(True), None))

    first, last, total = db.execute("select min(time), max(time), count(*) from heartbeat").fetchone()
    print(f"done: heartbeat now {total} rows from {first} to {last}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export", help="dump the old MariaDB tables to JSON lines")
    e.add_argument("--container", default="uptime-kuma")
    e.add_argument("--out", required=True)
    e.set_defaults(func=cmd_export)
    i = sub.add_parser("import", help="load them into the new SQLite database (new Kuma stopped)")
    i.add_argument("--export", required=True)
    i.add_argument("--db", required=True)
    i.set_defaults(func=cmd_import)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
