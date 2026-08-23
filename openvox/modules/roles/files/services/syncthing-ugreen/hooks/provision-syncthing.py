#!/usr/bin/env python3
"""Provision the Ugreen Syncthing node against the existing NAS-hub cluster.

Idempotent: safe to re-run on every deploy. Only creates what's missing;
never removes a device or folder, since that's exactly the kind of
irreversible action that shouldn't happen from an unattended deploy hook.

Two things this script does that the NAS's own Syncthing has never had done
to it before, discovered while investigating this repo's backup coverage:

  1. Creates 8 new folders that existed as plain directories under
     /mnt/user/Sync on the NAS but were never registered with Syncthing at
     all - six old semester folders (1_2021WS..6_2024SS) and two real,
     previously-unbacked-up directories (Home Assistant config snapshots,
     Mail .mbox archives). Each is archive-tier: shared with NAS + ugreen
     only, matching the pattern semesters 7-8 already used.
  2. Adds ugreen to every existing folder except Games.

Run with SERVICE_NAME/SERVICE_PATH/NAS_SYNCTHING_URL/NAS_SYNCTHING_API_KEY
already in the environment (see env.j2) by hooks/post-deploy.sh, which also
waits for both Syncthing instances to be reachable first.
"""

import json
import os
import sys
import urllib.error
import urllib.request

LOCAL_URL = "http://127.0.0.1:8384"
LOCAL_CONFIG_XML = "/volume1/homelab/syncthing/config/config.xml"
LOCAL_DATA_ROOT = "/var/syncthing"  # ugreen-side path, inside the container

# Archive folders that exist as directories on the NAS today but were never
# registered with Syncthing. Path is relative to the NAS's /data1 (which is
# /mnt/user/Sync on the host) and reused verbatim as the leaf directory name
# on ugreen too, so the same folder looks the same from either side.
NEW_ARCHIVE_FOLDERS = [
    "1_2021WS", "2_2022SS", "3_2022WS", "4_2023SS", "5_2023WS", "6_2024SS",
    "Home Assistant", "Mail",
]

EXCLUDED_LABELS = {"Games"}


def api(base_url, api_key, method, path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        base_url.rstrip("/") + path, data=data, method=method,
        headers={"X-API-Key": api_key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError("%s %s -> %s: %s" % (method, path, exc.code, detail))


def local_api_key():
    with open(LOCAL_CONFIG_XML, "r") as fh:
        content = fh.read()
    import re
    match = re.search(r"<apikey>([^<]+)</apikey>", content)
    if not match:
        raise RuntimeError("could not read API key from %s" % LOCAL_CONFIG_XML)
    return match.group(1)


def main():
    nas_url = os.environ["NAS_SYNCTHING_URL"]
    nas_key = os.environ["NAS_SYNCTHING_API_KEY"]
    local_key = local_api_key()

    local_status = api(LOCAL_URL, local_key, "GET", "/rest/system/status")
    local_device_id = local_status["myID"]
    print("ugreen device ID: %s" % local_device_id)

    nas_config = api(nas_url, nas_key, "GET", "/rest/config")
    nas_status = api(nas_url, nas_key, "GET", "/rest/system/status")
    nas_device_id = nas_status["myID"]

    existing_devices = {d["deviceID"]: d for d in nas_config["devices"]}
    existing_folders = {f["id"]: f for f in nas_config["folders"]}

    # --- 1. NAS side: register ugreen as a device -------------------------
    if local_device_id not in existing_devices:
        print("registering ugreen as a device on the NAS")
        api(nas_url, nas_key, "PUT", "/rest/config/devices/%s" % local_device_id, {
            "deviceID": local_device_id, "name": "ugreen",
        })
    else:
        print("ugreen already known to the NAS")

    # --- 2. NAS side: create the 8 archive folders if missing -------------
    # Folder IDs are derived, not guessed fresh each run, so re-running this
    # script always resolves to the same folder rather than creating
    # duplicates with a different generated ID.
    def archive_folder_id(name):
        return "archive-" + name.lower().replace(" ", "-")

    new_folder_ids = []
    for name in NEW_ARCHIVE_FOLDERS:
        fid = archive_folder_id(name)
        new_folder_ids.append(fid)
        if fid in existing_folders:
            print("archive folder already exists: %s" % name)
            continue
        print("creating archive folder on the NAS: %s" % name)
        api(nas_url, nas_key, "PUT", "/rest/config/folders/%s" % fid, {
            "id": fid,
            "label": name,
            "path": "/data1/%s" % name,
            "type": "sendreceive",
            "devices": [
                {"deviceID": nas_device_id},
                {"deviceID": local_device_id},
            ],
        })

    # --- 3. NAS side: add ugreen to every existing non-Games folder -------
    for fid, folder in existing_folders.items():
        if folder.get("label") in EXCLUDED_LABELS:
            continue
        device_ids = {d["deviceID"] for d in folder["devices"]}
        if local_device_id in device_ids:
            continue
        print("adding ugreen to existing folder: %s" % folder.get("label", fid))
        folder["devices"].append({"deviceID": local_device_id})
        api(nas_url, nas_key, "PUT", "/rest/config/folders/%s" % fid, folder)

    # Re-read: folder devices/paths are now authoritative for what ugreen
    # should mirror, including the archive folders just created above.
    nas_config = api(nas_url, nas_key, "GET", "/rest/config")
    nas_folders_by_id = {f["id"]: f for f in nas_config["folders"]}
    nas_devices_by_id = {d["deviceID"]: d for d in nas_config["devices"]}

    # --- 4. ugreen side: register every device the NAS knows about --------
    local_config = api(LOCAL_URL, local_key, "GET", "/rest/config")
    local_existing_devices = {d["deviceID"] for d in local_config["devices"]}
    for device_id, device in nas_devices_by_id.items():
        if device_id == local_device_id or device_id in local_existing_devices:
            continue
        print("registering device on ugreen: %s" % device.get("name", device_id))
        api(LOCAL_URL, local_key, "PUT", "/rest/config/devices/%s" % device_id, {
            "deviceID": device_id, "name": device.get("name", device_id[:8]),
        })

    # --- 5. ugreen side: accept every folder it was added to --------------
    local_config = api(LOCAL_URL, local_key, "GET", "/rest/config")
    local_existing_folders = {f["id"] for f in local_config["folders"]}
    for fid, folder in nas_folders_by_id.items():
        if folder.get("label") in EXCLUDED_LABELS:
            continue
        folder_device_ids = {d["deviceID"] for d in folder["devices"]}
        if local_device_id not in folder_device_ids:
            continue
        if fid in local_existing_folders:
            continue
        leaf = folder["path"].rsplit("/", 1)[-1]
        print("accepting folder on ugreen: %s" % folder.get("label", fid))
        api(LOCAL_URL, local_key, "PUT", "/rest/config/folders/%s" % fid, {
            "id": fid,
            "label": folder.get("label", fid),
            "path": "%s/%s" % (LOCAL_DATA_ROOT, leaf),
            "type": "sendreceive",
            "devices": [{"deviceID": d} for d in folder_device_ids],
        })

    print("done")


if __name__ == "__main__":
    sys.exit(main())
