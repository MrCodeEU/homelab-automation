#!/usr/bin/env bash
# Read-only remote half of schedule-check.sh (PHP is on Unraid for its web UI,
# so no executable has to be uploaded during a noop). Exit 0 when the start and
# stop entries exist as expected, the retired hand-made scripts are gone, and
# the runtime copy of schedule.json matches the flash copy.
set -euo pipefail
schedule=/boot/config/plugins/user.scripts/schedule.json
runtime=/tmp/user.scripts/schedule.json
base=/boot/config/plugins/user.scripts/scripts

# PHP variables are intentionally protected from shell expansion.
# shellcheck disable=SC2016
php -r '
  $data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
  $want = [
    "aoostar-display"      => ["start", "scheduleaoostardisplay"],
    "aoostar-display-stop" => ["stop",  "scheduleaoostardisplaystop"],
  ];
  foreach ($want as $name => [$freq, $id]) {
    $path = "$argv[2]/$name/script";
    $expected = ["script" => $path, "frequency" => $freq, "id" => $id, "custom" => ""];
    if (!isset($data[$path]) || $data[$path] != $expected) exit(1);
  }
  foreach (["aoostar_display", "aoostar_display_controller"] as $retired) {
    if (isset($data["$argv[2]/$retired/script"])) exit(1);
  }
' "$schedule" "$base"
cmp -s "$schedule" "$runtime"
[ ! -d "$base/aoostar_display" ] && [ ! -d "$base/aoostar_display_controller" ]
