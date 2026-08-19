# Ansible Homelab Map

Generated from `ansible/inventory/hosts.yml` and `ansible/inventory/group_vars/all/all.yml`.

## Summary

- Hosts: 6
- Inventory groups: 6
- Enabled services: 51
- Managed Compose services: 35
- Proxy-only services: 13

## Inventory

```mermaid
flowchart LR
  group_managed["managed"]
  group_proxy_only["proxy_only"]
  group_rocky["rocky"]
  group_ugreen["ugreen"]
  group_unraid["unraid"]
  group_wd_mycloud["wd_mycloud"]
  host_homeassistant["homeassistant<br/>100.100.10.200"]
  host_mljr["mljr<br/>100.100.20.1"]
  host_nas["nas<br/>100.100.10.2"]
  host_nuc["nuc<br/>100.100.10.1"]
  host_ugreen["ugreen<br/>100.100.10.4"]
  host_wd_mycloud["wd-mycloud<br/>100.100.10.5"]
  group_proxy_only --> host_homeassistant
  group_rocky --> host_mljr
  group_rocky --> host_nuc
  group_ugreen --> host_ugreen
  group_unraid --> host_nas
  group_wd_mycloud --> host_wd_mycloud
```

## Service Placement

```mermaid
flowchart LR
  svc_authelia["authelia<br/>managed<br/>auth.mljr.eu"]
  svc_authelia --> host_mljr
  svc_auto_media_sort["auto-media-sort<br/>proxy only<br/>sort.mljr.eu"]
  svc_auto_media_sort --> host_nas
  svc_cglab["cglab<br/>managed<br/>cglab.mljr.eu"]
  svc_cglab --> host_nuc
  svc_cockpit["cockpit<br/>proxy only<br/>cockpit.mljr.eu"]
  svc_cockpit --> host_mljr
  svc_codec["codec<br/>managed<br/>codec.mljr.eu"]
  svc_codec --> host_mljr
  svc_cron["cron<br/>managed<br/>cron.mljr.eu"]
  svc_cron --> host_mljr
  svc_crowdsec["crowdsec<br/>managed<br/>crowdsec.mljr.eu, security.mljr.eu"]
  svc_crowdsec --> host_mljr
  svc_dawarich["dawarich<br/>proxy only<br/>dawarich.mljr.eu"]
  svc_dawarich --> host_nas
  svc_diun["diun<br/>managed"]
  svc_diun --> host_mljr
  svc_dockhand["dockhand<br/>proxy only<br/>dockhand.mljr.eu"]
  svc_dockhand --> host_nas
  svc_endlessh["endlessh<br/>managed"]
  svc_endlessh --> host_mljr
  svc_forgejo["forgejo<br/>managed<br/>git.mljr.eu, forge.mljr.eu, fogrejo.mljr.eu"]
  svc_forgejo --> host_nuc
  svc_gameoflife["gameoflife<br/>managed<br/>gameoflife.mljr.eu"]
  svc_gameoflife --> host_nuc
  svc_glance["glance<br/>managed<br/>dash.mljr.eu"]
  svc_glance --> host_mljr
  svc_goaccess["goaccess<br/>managed<br/>logs.mljr.eu"]
  svc_goaccess --> host_mljr
  svc_godrive_demo["godrive-demo<br/>managed<br/>godrive.mljr.eu"]
  svc_godrive_demo --> host_nuc
  svc_grafana["grafana<br/>managed<br/>monitor.mljr.eu, grafana.mljr.eu"]
  svc_grafana --> host_nuc
  svc_healthreport["healthreport<br/>managed"]
  svc_healthreport --> host_nuc
  svc_hellpot["hellpot<br/>managed"]
  svc_hellpot --> host_mljr
  svc_homeassistant["homeassistant<br/>proxy only<br/>home.mljr.eu"]
  svc_homeassistant --> host_homeassistant
  svc_homepage["homepage<br/>managed<br/>mljr.eu"]
  svc_homepage --> host_mljr
  svc_immich["immich<br/>proxy only<br/>immich.mljr.eu"]
  svc_immich --> host_nas
  svc_kuma["kuma<br/>managed<br/>uptime.mljr.eu"]
  svc_kuma --> host_nuc
  svc_mailcow["mailcow<br/>managed<br/>mail.mljr.eu"]
  svc_mailcow --> host_mljr
  svc_nas["nas<br/>proxy only<br/>nas.mljr.eu"]
  svc_nas --> host_nas
  svc_nas_alloy["nas-alloy<br/>managed"]
  svc_nas_alloy --> host_nas
  svc_newsletter["newsletter<br/>managed<br/>newsletter.mljr.eu"]
  svc_newsletter --> host_mljr
  svc_nextcloud["nextcloud<br/>proxy only<br/>cloud.mljr.eu"]
  svc_nextcloud --> host_nas
  svc_nocturne["nocturne<br/>managed<br/>nc.mljr.eu"]
  svc_nocturne --> host_nuc
  svc_ntfy["ntfy<br/>managed<br/>ntfy.mljr.eu"]
  svc_ntfy --> host_mljr
  svc_nuc_webui["nuc-webui<br/>proxy only<br/>nuc.mljr.eu"]
  svc_nuc_webui --> host_nuc
  svc_ollama["ollama<br/>managed"]
  svc_ollama --> host_nas
  svc_oxicloud["oxicloud<br/>managed"]
  svc_oxicloud --> host_ugreen
  svc_projects["projects<br/>proxy only<br/>projects.mljr.eu"]
  svc_projects --> host_nas
  svc_regex["regex<br/>managed<br/>regex.mljr.eu"]
  svc_regex --> host_mljr
  svc_service_template["service-template<br/>managed<br/>template.mljr.eu"]
  svc_service_template --> host_nuc
  svc_smartctl_exporter["smartctl-exporter<br/>managed"]
  svc_smartctl_exporter --> host_ugreen
  svc_smartctl_exporter_nas["smartctl-exporter-nas<br/>managed"]
  svc_smartctl_exporter_nas --> host_nas
  svc_smartctl_exporter_nuc["smartctl-exporter-nuc<br/>managed"]
  svc_smartctl_exporter_nuc --> host_nuc
  svc_speedtest["speedtest<br/>managed<br/>speedtest.mljr.eu"]
  svc_speedtest --> host_nuc
  svc_spidertrap["spidertrap<br/>managed"]
  svc_spidertrap --> host_mljr
  svc_status["status<br/>proxy only<br/>status.mljr.eu"]
  svc_status --> host_mljr
  svc_sudoku["sudoku<br/>managed<br/>sudoku.mljr.eu"]
  svc_sudoku --> host_nuc
  svc_syncthing["syncthing<br/>proxy only<br/>sync.mljr.eu"]
  svc_syncthing --> host_nas
  svc_syncthing_ugreen["syncthing-ugreen<br/>managed"]
  svc_syncthing_ugreen --> host_ugreen
  svc_test_ocis["test-ocis<br/>proxy only<br/>ocis.mljr.eu"]
  svc_test_ocis --> host_nas
  svc_ui_showcase["ui-showcase<br/>managed<br/>ui.mljr.eu"]
  svc_ui_showcase --> host_mljr
  svc_umami["umami<br/>managed<br/>umami.mljr.eu"]
  svc_umami --> host_nuc
  svc_weather_cli["weather-cli<br/>managed<br/>weather-cli.mljr.eu"]
  svc_weather_cli --> host_mljr
  svc_wordwiz["wordwiz<br/>managed<br/>wordwiz.mljr.eu"]
  svc_wordwiz --> host_nuc
  classDef disabled fill:#f5f5f5,stroke:#999,color:#777,stroke-dasharray: 4 4;
```

## Services

| Service | Host | Mode | Domain |
|---------|------|------|--------|
| `authelia` | `mljr` | dedicated role | auth.mljr.eu |
| `auto-media-sort` | `nas` | proxy only | sort.mljr.eu |
| `cglab` | `nuc` | managed | cglab.mljr.eu |
| `cockpit` | `mljr` | proxy only | cockpit.mljr.eu |
| `codec` | `mljr` | managed | codec.mljr.eu |
| `cron` | `mljr` | managed | cron.mljr.eu |
| `crowdsec` | `mljr` | managed | crowdsec.mljr.eu, security.mljr.eu |
| `dawarich` | `nas` | proxy only | dawarich.mljr.eu |
| `diun` | `mljr` | managed |  |
| `dockhand` | `nas` | proxy only | dockhand.mljr.eu |
| `endlessh` | `mljr` | managed |  |
| `forgejo` | `nuc` | managed | git.mljr.eu, forge.mljr.eu, fogrejo.mljr.eu |
| `gameoflife` | `nuc` | managed | gameoflife.mljr.eu |
| `glance` | `mljr` | dedicated role | dash.mljr.eu |
| `goaccess` | `mljr` | managed | logs.mljr.eu |
| `godrive-demo` | `nuc` | managed | godrive.mljr.eu |
| `grafana` | `nuc` | managed | monitor.mljr.eu, grafana.mljr.eu |
| `healthreport` | `nuc` | managed |  |
| `hellpot` | `mljr` | managed |  |
| `homeassistant` | `homeassistant` | proxy only | home.mljr.eu |
| `homepage` | `mljr` | managed | mljr.eu |
| `immich` | `nas` | proxy only | immich.mljr.eu |
| `kuma` | `nuc` | managed | uptime.mljr.eu |
| `mailcow` | `mljr` | dedicated role | mail.mljr.eu |
| `nas` | `nas` | proxy only | nas.mljr.eu |
| `nas-alloy` | `nas` | managed |  |
| `newsletter` | `mljr` | managed | newsletter.mljr.eu |
| `nextcloud` | `nas` | proxy only | cloud.mljr.eu |
| `nocturne` | `nuc` | managed | nc.mljr.eu |
| `ntfy` | `mljr` | managed | ntfy.mljr.eu |
| `nuc-webui` | `nuc` | proxy only | nuc.mljr.eu |
| `ollama` | `nas` | managed |  |
| `oxicloud` | `ugreen` | managed |  |
| `projects` | `nas` | proxy only | projects.mljr.eu |
| `regex` | `mljr` | managed | regex.mljr.eu |
| `service-template` | `nuc` | managed | template.mljr.eu |
| `smartctl-exporter` | `ugreen` | managed |  |
| `smartctl-exporter-nas` | `nas` | managed |  |
| `smartctl-exporter-nuc` | `nuc` | managed |  |
| `speedtest` | `nuc` | managed | speedtest.mljr.eu |
| `spidertrap` | `mljr` | managed |  |
| `status` | `mljr` | proxy only | status.mljr.eu |
| `sudoku` | `nuc` | managed | sudoku.mljr.eu |
| `syncthing` | `nas` | proxy only | sync.mljr.eu |
| `syncthing-ugreen` | `ugreen` | managed |  |
| `test-ocis` | `nas` | proxy only | ocis.mljr.eu |
| `ui-showcase` | `mljr` | managed | ui.mljr.eu |
| `umami` | `nuc` | managed | umami.mljr.eu |
| `weather-cli` | `mljr` | managed | weather-cli.mljr.eu |
| `wordwiz` | `nuc` | managed | wordwiz.mljr.eu |
