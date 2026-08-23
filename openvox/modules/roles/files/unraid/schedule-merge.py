#!/usr/bin/env python3
# Merges the homelab-compose-up bootstrap entry into Unraid's User Scripts
# schedule.json (shared with UI-created entries, so it must be merged, not
# overwritten) and removes retired entries. Runs directly on nas (Python
# 3.9 confirmed present, no jq on this Slackware base). Logic-ported from
# spot/playbooks/unraid-bootstrap.yml's python heredoc (migration/spot,
# already validated live), adapted from spot's $CHECK_MODE-env-var
# convention to a plain --check argv flag with real exit-code semantics:
# exit 1 if anything would change (for use as a Puppet `unless`-inverted
# check), exit 0 if already clean or after a real apply.
import json
import os
import shutil
import sys

US_PATH = "/boot/config/plugins/user.scripts"
RUNTIME_PATH = "/tmp/user.scripts"
BOOTSTRAP_NAME = "homelab-compose-up"
BOOTSTRAP_SCRIPT_PATH = f"{US_PATH}/scripts/{BOOTSTRAP_NAME}/script"
# Legacy User Scripts entry superseded by Ansible/spot/OpenVox - "GHCR Auth"
# held a plaintext GitHub PAT on the boot flash; GHCR login now happens
# from the eyaml-held token instead (see roles::services once ported).
RETIRED = ["GHCR Auth"]
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
bootstrap_id = "schedule" + "".join(c for c in BOOTSTRAP_NAME if c.isalnum())
merged = dict(kept)
merged[BOOTSTRAP_SCRIPT_PATH] = {
    "script": BOOTSTRAP_SCRIPT_PATH,
    "frequency": "start",
    "id": bootstrap_id,
    "custom": "",
}
# sort_keys=True matches Ansible's to_nice_json (sorts by default) so
# re-serializing unchanged content is byte-identical - without it every
# run would show spurious drift from key reordering alone.
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
        # backup: true can't be used here - the boot flash is vfat, and
        # timestamp-embedded backup filenames contain colons, which vfat
        # rejects with EINVAL. Keep a single fixed-name copy instead.
        shutil.copyfile(SCHEDULE_PATH, BACKUP_PATH)
        os.chmod(BACKUP_PATH, 0o644)
    os.makedirs(US_PATH, exist_ok=True)
    with open(SCHEDULE_PATH, "w") as f:
        f.write(merged_json)
    os.chmod(SCHEDULE_PATH, 0o644)
    print(f"merged {SCHEDULE_PATH}")

# The scheduler does not read the flash copy - cron.daily/hourly/weekly
# run startSchedule.php, which loads this runtime copy, refreshed by the
# plugin only at boot or when its settings page is saved. Always
# re-mirror (cheap, keeps it correct even if only the runtime copy went
# stale).
os.makedirs(RUNTIME_PATH, exist_ok=True)
shutil.copyfile(SCHEDULE_PATH, f"{RUNTIME_PATH}/schedule.json")
os.chmod(f"{RUNTIME_PATH}/schedule.json", 0o600)

for n in RETIRED:
    d = f"{US_PATH}/scripts/{n}"
    if os.path.isdir(d):
        shutil.rmtree(d)
        print(f"removed retired user script '{n}'")

print("bootstrap schedule merge complete")
