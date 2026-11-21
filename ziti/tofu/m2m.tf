# Machine-to-machine consumers that cannot dial Ziti themselves go through
# `ziti-tcp-proxy` (tools/cmd/ziti-tcp-proxy): one per host for host-network apps (Alloy,
# services/ziti-proxy*), one inside the compose project for a bridged app
# (homepage, crowdsec-nuc, speedtest-metrics). Each has its own identity, enrolled on its host by
# scripts/ziti-enroll-proxy.sh so the key never leaves it. Each identity may dial only the services
# listed here, by name; it hosts nothing.
locals {
  m2m = {
    # Alloy on mljr -> VictoriaMetrics and Loki on nuc; backups -> ugreen;
    # home-ip sync -> home-ip serve on nuc (home-ip.tf); Trivy/Nuclei
    # imports -> DefectDojo on nuc (roles::vuln_scan)
    "m2m-mljr" = ["grafana-victoriametrics", "grafana-loki", "backup-sftp-ugreen", "home-ip-nuc", "defectdojo"]
    # Backups on nuc -> ugreen; healthreport and backup-dashboard facts
    # over SSH -> mljr, ugreen (services/ziti-proxy-nuc)
    "m2m-nuc" = ["backup-sftp-ugreen", "facts-ssh-mljr", "facts-ssh-ugreen"]
    # Alloy on ugreen -> the same; Trivy imports -> DefectDojo
    "m2m-ugreen" = ["grafana-victoriametrics", "grafana-loki", "defectdojo"]
    # homepage on mljr (live homelab panel) -> VictoriaMetrics, PromQL
    "homepage-mljr" = ["grafana-victoriametrics"]
    # CrowdSec agent on nuc -> mljr's LAPI (crowdsec-nas stays on the
    # tailnet until nas is on Ziti, Phase 5)
    "crowdsec-nuc" = ["crowdsec-lapi"]
    # Uptime Kuma on nuc: checks that would otherwise need the tailnet
    # (services/kuma, kuma-ziti-proxy)
    "kuma-nuc" = ["crowdsec-lapi", "mail-smtp-mljr", "defectdojo"]
    # speedtest-metrics on nuc -> iperf3 on mljr and ugreen (iperf3.tf)
    "speedtest-nuc" = ["iperf3-mljr", "iperf3-ugreen"]
  }

  # Where each one runs, for its edge routers (policies.tf).
  m2m_site = {
    "m2m-mljr"      = "at-mljr"
    "homepage-mljr" = "at-mljr"
    "m2m-nuc"       = "at-home"
    "m2m-ugreen"    = "at-home"
    "crowdsec-nuc"  = "at-home"
    "kuma-nuc"      = "at-home"
    "speedtest-nuc" = "at-home"
  }

  # Dialable by name: catalog services, iperf3, SSH, mail SMTP, backup SFTP
  m2m_services = merge(ziti_service.catalog, local.iperf3_services, local.facts_ssh_services, {
    (ziti_service.mail_smtp_mljr.name) = ziti_service.mail_smtp_mljr,
    (ziti_service.backup_sftp.name)    = ziti_service.backup_sftp,
    (ziti_service.home_ip_nuc.name)    = ziti_service.home_ip_nuc
  })
}

resource "ziti_identity" "m2m" {
  for_each        = local.m2m
  name            = each.key
  type            = "Default"
  auth_policy_id  = "default"
  role_attributes = [local.m2m_site[each.key]]
}

resource "ziti_service_policy" "m2m_dial" {
  for_each      = local.m2m
  name          = "${each.key}-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = ["@${ziti_identity.m2m[each.key].id}"]
  serviceroles  = sort([for s in each.value : "@${local.m2m_services[s].id}"])
}
