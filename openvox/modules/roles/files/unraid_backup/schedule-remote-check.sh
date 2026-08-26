#!/usr/bin/env bash
# Read-only remote half of schedule-check.sh. Kept beside this proxy role so
# Puppet can distribute it without coupling the two Unraid role file trees.
set -euo pipefail

schedule=/boot/config/plugins/user.scripts/schedule.json
runtime=/tmp/user.scripts/schedule.json
script_path="/boot/config/plugins/user.scripts/scripts/${SCRIPT_NAME}/script"

php -r '
  $data = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
  $path = $argv[2];
  $expected = ["script" => $path, "frequency" => $argv[3], "id" => $argv[4], "custom" => ""];
  if (!isset($data[$path]) || $data[$path] != $expected) exit(1);
  foreach (array_slice($argv, 5) as $retired) {
    $retiredPath = "/boot/config/plugins/user.scripts/scripts/{$retired}/script";
    if (isset($data[$retiredPath])) exit(1);
  }
' "$schedule" "$script_path" "$FREQUENCY" "schedule${SCRIPT_NAME//[^[:alnum:]]/}" "$RETIRED"

cmp -s "$schedule" "$runtime"
[ ! -d "/boot/config/plugins/user.scripts/scripts/$RETIRED" ]
