#!/usr/bin/env python3
# Merges the nas-backup entry into Unraid's User Scripts schedule.json and
# removes the retired manual "rclone backup" script. Same shape as
# roles::unraid_proxy's schedule-merge.py (see that file for the full
# design rationale) - kept as a separate copy rather than a shared/
# parameterized script since the two roles' Ansible/spot ancestors were
# also always two separate scripts, not one shared with flags.
import json
import os
import shutil
import sys

US_PATH = "/boot/config/plugins/user.scripts"
RUNTIME_PATH = "/tmp/user.scripts"
SCRIPT_NAME = "nas-backup"
SCRIPT_PATH = f"{US_PATH}/scripts/{SCRIPT_NAME}/script"
# The manual "rclone backup" User Script this role replaces.
RETIRED = ["rclone backup"]
RETIRED_PATHS = [f"{US_PATH}/scripts/{n}/script" for n in RETIRED]
SCHEDULE_PATH = f"{US_PATH}/schedule.json"
BACKUP_PATH = f"{US_PATH}/schedule.json.openvox-bak"

check_only = "--check" in sys.argv

existed_before = os.path.exists(SCHEDULE_PATH)
existing_raw = ""
existing = {}
if existed_before:
    with open(SCHEDULE_PATH) as f:
        existing_raw = f.read()
    existing = json.loads(existing_raw) if existing_raw.strip() else {}

kept = {k: v for k, v in existing.items() if k not in RETIRED_PATHS}
schedule_id = "schedule" + "".join(c for c in SCRIPT_NAME if c.isalnum())
merged = dict(kept)
merged[SCRIPT_PATH] = {
    "script": SCRIPT_PATH,
    "frequency": "daily",
    "id": schedule_id,
    "custom": "",
}
merged_json = json.dumps(merged, indent=4, sort_keys=True) + "\n"

schedule_changed = merged_json != existing_raw
retired_dirs_present = [n for n in RETIRED if os.path.isdir(f"{US_PATH}/scripts/{n}")]
runtime_file = f"{RUNTIME_PATH}/schedule.json"
if os.path.exists(runtime_file):
    with open(runtime_file) as f:
        runtime_stale = f.read() != merged_json
else:
    runtime_stale = True

if check_only:
    dirty = schedule_changed or retired_dirs_present or runtime_stale
    sys.exit(1 if dirty else 0)

if schedule_changed:
    if existed_before:
        shutil.copyfile(SCHEDULE_PATH, BACKUP_PATH)
        os.chmod(BACKUP_PATH, 0o644)
    os.makedirs(US_PATH, exist_ok=True)
    with open(SCHEDULE_PATH, "w") as f:
        f.write(merged_json)
    os.chmod(SCHEDULE_PATH, 0o644)
    print(f"merged {SCHEDULE_PATH}")

os.makedirs(RUNTIME_PATH, exist_ok=True)
shutil.copyfile(SCHEDULE_PATH, runtime_file)
os.chmod(runtime_file, 0o600)

for n in RETIRED:
    d = f"{US_PATH}/scripts/{n}"
    if os.path.isdir(d):
        shutil.rmtree(d)
        print(f"removed retired user script '{n}'")

print("backup schedule merge complete")
