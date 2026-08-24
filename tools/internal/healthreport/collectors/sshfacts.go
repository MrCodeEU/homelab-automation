// Facts that are not reachable over the network. CrowdSec's LAPI is
// loopback-bound on mljr, the nftables ruleset is root-only, and Unraid
// array/SMART state is not a network resource at all. Each host runs a
// read-only script behind an SSH key restricted to that exact command.
//
// The local host runs the script directly rather than dialling itself.
package collectors

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"time"

	hr "github.com/MrCodeEU/homelab-automation/tools/internal/healthreport"
)

var sshOptions = []string{
	"-o", "BatchMode=yes",
	"-o", "ConnectTimeout=10",
	"-o", "StrictHostKeyChecking=accept-new",
	"-o", "IdentitiesOnly=yes",
}

func fetchFacts(cfg hr.Config, host, address string) (map[string]any, error) {
	var args []string
	if host == cfg.LocalHost {
		args = []string{cfg.LocalFactsBin}
	} else {
		// The command is named explicitly rather than relying on the
		// authorized_keys forced command. Tailscale SSH terminates port
		// 22 on the tailnet interface and authorizes from the tailnet
		// ACL without ever reading authorized_keys, so the forced
		// command does not apply on this path and a bare `ssh` yields a
		// login shell that returns nothing. Naming it is correct in both
		// worlds: where real sshd does handle the connection, the forced
		// command overrides whatever is requested here.
		args = append([]string{"ssh"}, sshOptions...)
		args = append(args, "-i", cfg.SSHKeyPath, "root@"+address, cfg.LocalFactsBin)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	stdout, err := cmd.Output()
	if err != nil {
		var stderr []byte
		if exitErr, ok := err.(*exec.ExitError); ok {
			stderr = exitErr.Stderr
		}
		msg := string(stderr)
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return nil, fmt.Errorf("%s: exit %v: %s", host, err, msg)
	}

	var payload map[string]any
	if err := json.Unmarshal(stdout, &payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func init() {
	hr.RegisterCollector("ssh_facts", collectSSHFacts)
}

func collectSSHFacts(cfg hr.Config, rules hr.RulesFile) *hr.CollectorResult {
	result := hr.NewCollectorResult("ssh_facts")
	payloads := map[string]map[string]any{}
	errors := map[string]string{}

	targets := map[string]string{}
	for k, v := range cfg.SSHHosts {
		targets[k] = v
	}
	if _, ok := targets[cfg.LocalHost]; !ok && cfg.LocalHost != "" {
		if _, err := os.Stat(cfg.LocalFactsBin); err == nil {
			targets[cfg.LocalHost] = "local"
		}
	}

	if len(targets) == 0 {
		result.Status = "unavailable"
		result.Error = "no facts endpoints configured (HEALTHREPORT_SSH_HOSTS)"
		return result
	}

	hosts := make([]string, 0, len(targets))
	for h := range targets {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)

	for _, host := range hosts {
		payload, err := fetchFacts(cfg, host, targets[host])
		if err != nil {
			msg := err.Error()
			if len(msg) > 300 {
				msg = msg[:300]
			}
			errors[host] = msg
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "facts_unreachable." + host + ".", Collector: "ssh_facts", Subject: host,
				Kind: "facts_unreachable", Value: truncate(err.Error(), 200),
				Message:  "could not read host facts from " + host,
				Evidence: map[string]any{"error": msg}, Severity: "info",
			})
			continue
		}
		payloads[host] = payload
	}

	payloadHosts := make([]string, 0, len(payloads))
	for h := range payloads {
		payloadHosts = append(payloadHosts, h)
	}
	sort.Strings(payloadHosts)

	for _, host := range payloadHosts {
		payload := payloads[host]
		sections, _ := payload["sections"].(map[string]any)
		rockyObservations(result, host, sections)
		unraidObservations(result, host, sections, cfg)
		ugreenObservations(result, host, sections)

		sectionNames := make([]string, 0, len(sections))
		for name := range sections {
			sectionNames = append(sectionNames, name)
		}
		sort.Strings(sectionNames)
		for _, name := range sectionNames {
			section, _ := sections[name].(map[string]any)
			status, _ := section["status"].(string)
			if status != "ok" {
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("facts_section_failed.%s.%s", host, name), Collector: "ssh_facts",
					Subject: host, Kind: "facts_section_failed", Value: name,
					Message:  fmt.Sprintf("%s: facts section %s failed: %v", host, name, section["error"]),
					Evidence: map[string]any{"error": section["error"]}, Severity: "info",
				})
			}
		}
	}

	if len(errors) > 0 && len(payloads) == 0 {
		result.Status = "error"
	}
	if len(errors) > 0 {
		parts := make([]string, 0, len(errors))
		errHosts := make([]string, 0, len(errors))
		for h := range errors {
			errHosts = append(errHosts, h)
		}
		sort.Strings(errHosts)
		for _, h := range errHosts {
			parts = append(parts, h+": "+errors[h])
		}
		result.Error = joinSemicolon(parts)
	}

	result.Data = &hr.SSHFactsData{Hosts: payloadHosts, Errors: errors, Payloads: payloads}
	return result
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func joinSemicolon(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += "; "
		}
		out += p
	}
	return out
}

func section(sections map[string]any, name string) (map[string]any, bool) {
	entry, _ := sections[name].(map[string]any)
	if entry == nil {
		return nil, false
	}
	if status, _ := entry["status"].(string); status != "ok" {
		return nil, false
	}
	data, _ := entry["data"].(map[string]any)
	return data, true
}

func rockyObservations(result *hr.CollectorResult, host string, sections map[string]any) {
	if updates, ok := section(sections, "security_updates"); ok {
		count := int(numOr(updates["count"], 0))
		rebootRequired := boolOr(updates["reboot_required"])

		detail := fmt.Sprintf("%d advisories", count)
		if packages, ok := updates["distinct_package_count"]; ok && packages != nil {
			detail += fmt.Sprintf(" across %d package(s)", int(numOr(packages, 0)))
		}
		if rebootRequired {
			detail += ", already installed and pending reboot"
		}

		advisories, _ := updates["advisories"].([]any)
		distinctPackages, _ := updates["distinct_packages"].([]any)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "security_updates." + host + ".", Collector: "ssh_facts", Subject: host,
			Kind: "security_updates", Value: count, Unit: "advisories",
			Message: fmt.Sprintf("%s: %s", host, detail),
			Evidence: map[string]any{
				"advisories": firstN(advisories, 10), "distinct_packages": firstN(distinctPackages, 20),
				"reboot_required": rebootRequired, "running_kernel": updates["running_kernel"],
			},
			Severity: "info",
		})

		if rebootRequired {
			kernel := updates["running_kernel"]
			value := any(true)
			if k, ok := kernel.(string); ok && k != "" {
				value = k
			}
			kernelLabel := "unknown kernel"
			if k, ok := kernel.(string); ok && k != "" {
				kernelLabel = k
			}
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "reboot_required." + host + ".", Collector: "ssh_facts", Subject: host,
				Kind: "reboot_required", Value: value,
				Message: fmt.Sprintf("%s needs a reboot to activate installed updates (running %s)", host, kernelLabel),
				Evidence: map[string]any{"running_kernel": kernel, "advisories_pending_reboot": count},
				Severity: "info",
			})
		}
	}

	if crowdsec, hasCS := sections["crowdsec"].(map[string]any); hasCS {
		status, _ := crowdsec["status"].(string)
		data, _ := crowdsec["data"].(map[string]any)
		if status == "ok" && boolOr(data["available"]) {
			decisions, _ := data["decisions"].([]any)
			var sample []any
			for i, d := range decisions {
				if i >= 10 {
					break
				}
				if dm, ok := d.(map[string]any); ok {
					sample = append(sample, dm["value"])
				}
			}
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "crowdsec_decisions." + host + ".", Collector: "ssh_facts", Subject: host,
				Kind: "crowdsec_decisions", Value: len(decisions), Unit: "decisions",
				Message:  fmt.Sprintf("%s: CrowdSec is enforcing %d decisions", host, len(decisions)),
				Evidence: map[string]any{"sample": sample}, Severity: "info",
			})
			bouncers, _ := data["bouncers"].([]any)
			for _, b := range bouncers {
				bouncer, _ := b.(map[string]any)
				name, _ := bouncer["name"].(string)
				if name == "" {
					name = "unknown"
				}
				revoked := fmt.Sprint(bouncer["revoked"]) == "true"
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("crowdsec_bouncer.%s.%s", host, name), Collector: "ssh_facts",
					Subject: host, Kind: "crowdsec_bouncer", Value: !revoked,
					Message:  fmt.Sprintf("%s: CrowdSec bouncer %s last seen %v", host, name, orDefault(bouncer["last_pull"], "never")),
					Evidence: map[string]any{"last_pull": bouncer["last_pull"]}, Severity: "info",
				})
			}
		} else if status == "ok" && data != nil {
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "crowdsec_absent." + host + ".", Collector: "ssh_facts", Subject: host,
				Kind: "crowdsec_absent", Value: data["reason"],
				Message:  fmt.Sprintf("%s: CrowdSec not available (%v)", host, data["reason"]),
				Evidence: map[string]any{}, Severity: "info",
			})
		}
	}

	if nft, ok := section(sections, "nftables"); ok && nft["error"] == nil {
		tables, _ := nft["tables"].([]any)
		tableNames := make([]string, 0, len(tables))
		for _, t := range tables {
			tableNames = append(tableNames, fmt.Sprint(t))
		}
		ruleCount := int(numOr(nft["rule_count"], 0))
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "firewall_rules." + host + ".", Collector: "ssh_facts", Subject: host,
			Kind: "firewall_rules", Value: ruleCount, Unit: "rules",
			Message:  fmt.Sprintf("%s firewall has %d rules across %s", host, ruleCount, joinComma(tableNames)),
			Evidence: map[string]any{"set_element_counts": nft["set_element_counts"]}, Severity: "info",
		})
	}

	// Capacity of the backup destinations themselves.
	if targets, ok := section(sections, "backup_targets"); ok {
		items, _ := targets["targets"].([]any)
		for _, raw := range items {
			target, _ := raw.(map[string]any)
			if target == nil || !boolOr(target["quota_supported"]) || target["used_percent"] == nil {
				continue
			}
			usedPercent := numOr(target["used_percent"], 0)
			freeGiB := numOr(target["free_bytes"], 0) / (1024.0 * 1024.0 * 1024.0)
			name := fmt.Sprint(target["name"])
			result.Observations = append(result.Observations, &hr.Observation{
				ID: fmt.Sprintf("backup_target_usage.%s.%s", host, name), Collector: "ssh_facts",
				Subject: host, Kind: "backup_target_usage", Value: usedPercent, Unit: "percent",
				Message: fmt.Sprintf("backup target %s is %.1f%% full (%.0f GiB free)", name, usedPercent, freeGiB),
				Evidence: map[string]any{
					"kind": target["kind"], "total_bytes": target["total_bytes"], "free_bytes": target["free_bytes"],
				},
				Severity: "info",
			})
		}
	}

	// Kernel-level trouble.
	if kernel, hasKernel := sections["kernel_errors"].(map[string]any); hasKernel {
		data, _ := kernel["data"].(map[string]any)
		if data != nil && boolOr(data["available"]) {
			serious := int(numOr(data["serious_count"], 0))
			if serious > 0 {
				sample, _ := data["serious_sample"].([]any)
				result.Observations = append(result.Observations, &hr.Observation{
					ID: "kernel_storage_errors." + host + ".", Collector: "ssh_facts", Subject: host,
					Kind: "kernel_storage_errors", Value: serious, Unit: "messages",
					Message:  fmt.Sprintf("%s: %d kernel message(s) indicating disk, filesystem or memory trouble", host, serious),
					Evidence: map[string]any{"sample": firstN(sample, 5)}, Severity: "info",
				})
			}
		}
	}

	// Clock drift breaks log correlation and TOTP before anything else notices.
	if clock, hasClock := sections["time_sync"].(map[string]any); hasClock {
		data, _ := clock["data"].(map[string]any)
		if data != nil && boolOr(data["available"]) {
			synchronised := true
			if v, ok := data["synchronised"]; ok {
				synchronised = boolOr(v)
			}
			if !synchronised {
				reason := data["reason"]
				if reason == nil {
					reason = data["source"]
				}
				result.Observations = append(result.Observations, &hr.Observation{
					ID: "time_unsynchronised." + host + ".", Collector: "ssh_facts", Subject: host,
					Kind: "time_unsynchronised", Value: orDefault(data["source"], "unknown"),
					Message:  fmt.Sprintf("%s: clock is not synchronised (%v)", host, reason),
					Evidence: map[string]any{"source": data["source"]}, Severity: "info",
				})
			} else if data["offset_seconds"] != nil {
				offset := numOr(data["offset_seconds"], 0)
				result.Observations = append(result.Observations, &hr.Observation{
					ID: "time_offset." + host + ".", Collector: "ssh_facts", Subject: host,
					Kind: "time_offset", Value: round3(offset), Unit: "seconds",
					Message:  fmt.Sprintf("%s clock offset %.3fs (%v, stratum %v)", host, offset, data["source"], data["stratum"]),
					Evidence: map[string]any{"source": data["source"]}, Severity: "info",
				})
			}
		}
	}

	if backup, hasBackup := sections["backup"].(map[string]any); hasBackup {
		data, _ := backup["data"].(map[string]any)
		if data != nil && boolOr(data["available"]) {
			ageH := numOr(data["age_seconds"], 0) / 3600.0
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "backup_age." + host + ".", Collector: "ssh_facts", Subject: host,
				Kind: "backup_age", Value: round1(ageH), Unit: "hours",
				Message:  fmt.Sprintf("%s last backup ran %.1f hours ago", host, ageH),
				Evidence: map[string]any{"file": data["file"]}, Severity: "info",
			})
			if boolOr(data["completed"]) {
				failedServices, _ := data["failed_services"].([]any)
				critical := int(numOr(data["critical_failures"], 0))
				nonCritical := int(numOr(data["non_critical_failures"], 0))
				suffix := ""
				if len(failedServices) > 0 {
					names := make([]string, 0, len(failedServices))
					for _, s := range failedServices {
						names = append(names, fmt.Sprint(s))
					}
					suffix = " (" + joinComma(names) + ")"
				}
				result.Observations = append(result.Observations, &hr.Observation{
					ID: "backup_failures." + host + ".", Collector: "ssh_facts", Subject: host,
					Kind: "backup_failures", Value: critical, Unit: "critical_failures",
					Message:  fmt.Sprintf("%s backup: %d critical, %d non-critical failures%s", host, critical, nonCritical, suffix),
					Evidence: map[string]any{"failed_services": failedServices}, Severity: "info",
				})
				for _, s := range failedServices {
					serviceName := fmt.Sprint(s)
					result.Observations = append(result.Observations, &hr.Observation{
						ID: fmt.Sprintf("backup_service_failed.%s.%s", host, serviceName), Collector: "ssh_facts",
						Subject: host, Kind: "backup_service_failed", Value: serviceName,
						Message:  fmt.Sprintf("%s: backup of %s failed", host, serviceName),
						Evidence: map[string]any{}, Severity: "info",
					})
				}
			} else {
				result.Observations = append(result.Observations, &hr.Observation{
					ID: "backup_incomplete." + host + ".", Collector: "ssh_facts", Subject: host,
					Kind: "backup_incomplete", Value: true,
					Message:  fmt.Sprintf("%s: last backup log has no summary - the run did not finish", host),
					Evidence: map[string]any{"file": data["file"]}, Severity: "info",
				})
			}
		} else if data != nil {
			result.Observations = append(result.Observations, &hr.Observation{
				ID: "backup_missing." + host + ".", Collector: "ssh_facts", Subject: host,
				Kind: "backup_missing", Value: data["reason"],
				Message:  fmt.Sprintf("%s: no backup log found (%v)", host, data["reason"]),
				Evidence: map[string]any{}, Severity: "info",
			})
		}
	}
}

func ugreenObservations(result *hr.CollectorResult, host string, sections map[string]any) {
	storage, ok := section(sections, "ugreen_storage")
	if !ok {
		return
	}

	mdraid, _ := storage["mdraid"].([]any)
	for _, raw := range mdraid {
		array, _ := raw.(map[string]any)
		if array == nil || !boolOr(array["degraded"]) {
			continue
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("mdraid_degraded.%s.%v", host, array["array"]), Collector: "ssh_facts",
			Subject: host, Kind: "mdraid_degraded", Value: array["status"],
			Message: fmt.Sprintf("%s: mdraid array %v is degraded (%v, status %v)",
				host, array["array"], array["members"], array["status"]),
			Evidence: array, Severity: "info",
		})
	}

	// LVM free space, mainly for the NVMe bcache tier.
	lvm, _ := storage["lvm"].([]any)
	for _, raw := range lvm {
		lv, _ := raw.(map[string]any)
		if lv == nil || lv["data_percent"] == nil {
			continue
		}
		percent := numOr(lv["data_percent"], 0)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: fmt.Sprintf("lvm_usage.%s.%v-%v", host, lv["vg"], lv["lv"]), Collector: "ssh_facts",
			Subject: host, Kind: "lvm_usage", Value: round1(percent), Unit: "percent",
			Message:  fmt.Sprintf("%s: LV %v/%v is %.1f%% full", host, lv["vg"], lv["lv"], percent),
			Evidence: lv, Severity: "info",
		})
	}
}

func unraidObservations(result *hr.CollectorResult, host string, sections map[string]any, cfg hr.Config) {
	if array, ok := section(sections, "unraid_array"); ok {
		disks, _ := array["disks"].([]any)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "array_state." + host + ".", Collector: "ssh_facts", Subject: host,
			Kind: "array_state", Value: array["state"],
			Message:  fmt.Sprintf("%s array is %v", host, array["state"]),
			Evidence: map[string]any{"disks": len(disks)}, Severity: "info",
		})
		syncErrors := array["sync_errors"]
		if syncErrors == nil {
			syncErrors = 0
		}
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "parity_sync_errors." + host + ".", Collector: "ssh_facts", Subject: host,
			Kind: "parity_sync_errors", Value: numOr(syncErrors, 0), Unit: "errors",
			Message:  fmt.Sprintf("%s parity reports %v sync errors", host, array["sync_errors"]),
			Evidence: map[string]any{}, Severity: "info",
		})
		if age := array["last_check_age_seconds"]; age != nil {
			ageF := numOr(age, 0)
			if ageF != 0 {
				result.Observations = append(result.Observations, &hr.Observation{
					ID: "parity_check_age." + host + ".", Collector: "ssh_facts", Subject: host,
					Kind: "parity_check_age", Value: round1(ageF / 86400.0), Unit: "days",
					Message:  fmt.Sprintf("%s last parity check finished %.1f days ago", host, ageF/86400.0),
					Evidence: map[string]any{"exit_code": array["sync_exit_code"]}, Severity: "info",
				})
			}
		}
		for _, raw := range disks {
			disk, _ := raw.(map[string]any)
			if disk == nil {
				continue
			}
			status := disk["status"]
			idPart := disk["name"]
			if idPart == nil {
				idPart = disk["slot"]
			}
			result.Observations = append(result.Observations, &hr.Observation{
				ID: fmt.Sprintf("array_disk.%s.%v", host, idPart), Collector: "ssh_facts", Subject: host,
				Kind: "array_disk", Value: status,
				Message:  fmt.Sprintf("%s disk %v is %v", host, disk["name"], status),
				Evidence: map[string]any{"id": disk["id"]}, Severity: "info",
			})
		}
	}

	smart, hasSmart := section(sections, "smart")
	if !hasSmart {
		smart, hasSmart = section(sections, "unraid_smart")
	}
	if hasSmart {
		devices, _ := smart["devices"].([]any)
		for _, raw := range devices {
			device, _ := raw.(map[string]any)
			if device == nil || device["error"] != nil {
				continue
			}
			name := device["device"]
			if name == nil {
				name = "unknown"
			}
			for _, field := range []string{"reallocated_sectors", "pending_sectors"} {
				value, ok := device[field]
				if !ok || value == nil {
					continue
				}
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("%s.%s.%v", field, host, name), Collector: "ssh_facts", Subject: host,
					Kind: field, Value: value, Unit: "sectors",
					Message:  fmt.Sprintf("%s %v %s: %v", host, name, fieldLabel(field), value),
					Evidence: map[string]any{"model": device["model"]}, Severity: "info",
				})
			}
		}
	}

	if dockerImage, ok := section(sections, "unraid_docker_image"); ok && dockerImage["used_percent"] != nil {
		used := numOr(dockerImage["used_percent"], 0)
		result.Observations = append(result.Observations, &hr.Observation{
			ID: "docker_image_usage." + host + ".", Collector: "ssh_facts", Subject: host,
			Kind: "docker_image_usage", Value: used, Unit: "percent",
			Message:  fmt.Sprintf("%s docker.img is %.1f%% full", host, used),
			Evidence: map[string]any{"path": dockerImage["image_path"]}, Severity: "info",
		})
	}

	// Unraid keeps every unread notification as its own file, so a
	// recurring problem produces one per occurrence. Collapse by event
	// and severity so a repeating issue is one finding with a count.
	if notifRaw, has := sections["unraid_notifications"].(map[string]any); has {
		status, _ := notifRaw["status"].(string)
		if status == "ok" {
			list, _ := notifRaw["data"].([]any)
			type groupKey struct{ event, importance string }
			type groupEntry struct {
				count       int
				subject     string
				description string
			}
			grouped := map[groupKey]*groupEntry{}
			var order []groupKey
			for _, raw := range list {
				note, _ := raw.(map[string]any)
				if note == nil {
					continue
				}
				event, _ := note["event"].(string)
				if event == "" {
					event = "notification"
				}
				importance, _ := note["importance"].(string)
				if importance == "" {
					importance = "normal"
				}
				key := groupKey{event, importance}
				entry, ok := grouped[key]
				if !ok {
					subj, _ := note["subject"].(string)
					if subj == "" {
						subj = "?"
					}
					desc, _ := note["description"].(string)
					entry = &groupEntry{subject: subj, description: desc}
					grouped[key] = entry
					order = append(order, key)
				}
				entry.count++
			}
			sort.Slice(order, func(i, j int) bool {
				if order[i].event != order[j].event {
					return order[i].event < order[j].event
				}
				return order[i].importance < order[j].importance
			})
			for _, key := range order {
				entry := grouped[key]
				suffix := ""
				if entry.count != 1 {
					suffix = fmt.Sprintf(" (x%d unread)", entry.count)
				}
				desc := entry.description
				if len(desc) > 120 {
					desc = desc[:120]
				}
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("unraid_notification.%s.%s/%s", host, key.event, key.importance), Collector: "ssh_facts",
					Subject: host, Kind: "unraid_notification", Value: key.importance,
					Message:  fmt.Sprintf("%s notification: %s - %s%s", host, entry.subject, desc, suffix),
					Evidence: map[string]any{"event": key.event, "importance": key.importance, "unread": entry.count},
					Severity: "info",
				})
			}
		}
	}

	// Backup coverage drift: a subfolder inside a watched directory that
	// is neither a known backup source nor on the excluded allowlist.
	if watched, ok := section(sections, "watched_dirs"); ok {
		known := map[string]bool{}
		for _, p := range cfg.BackupKnownPaths {
			known[p] = true
		}
		excluded := map[string]bool{}
		for _, p := range cfg.BackupExcludedPaths {
			excluded[p] = true
		}
		watchDirs := map[string]bool{}
		for base := range watched {
			watchDirs[base] = true
		}
		bases := make([]string, 0, len(watched))
		for base := range watched {
			bases = append(bases, base)
		}
		sort.Strings(bases)
		for _, base := range bases {
			children := watched[base]
			if childMap, ok := children.(map[string]any); ok {
				if childMap["error"] != nil {
					continue
				}
			}
			childList, _ := children.([]any)
			for _, c := range childList {
				name := fmt.Sprint(c)
				childPath := base + "/" + name
				if watchDirs[childPath] || known[childPath] || excluded[childPath] {
					continue
				}
				result.Observations = append(result.Observations, &hr.Observation{
					ID: fmt.Sprintf("backup_drift.%s.%s", host, childPath), Collector: "ssh_facts",
					Subject: host, Kind: "backup_drift", Value: childPath,
					Message:  fmt.Sprintf("%s: %s is not backed up and not on the excluded list", host, childPath),
					Evidence: map[string]any{"watch_dir": base}, Severity: "info",
				})
			}
		}
	}
}

func fieldLabel(field string) string {
	out := ""
	for _, r := range field {
		if r == '_' {
			out += " "
		} else {
			out += string(r)
		}
	}
	return out
}

func numOr(v any, def float64) float64 {
	f, ok := numericAny(v)
	if !ok {
		return def
	}
	return f
}

func numericAny(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	default:
		return 0, false
	}
}

func boolOr(v any) bool {
	switch b := v.(type) {
	case bool:
		return b
	case nil:
		return false
	case float64:
		return b != 0
	case string:
		return b != "" && b != "false"
	default:
		return false
	}
}

func orDefault(v any, def string) any {
	if v == nil {
		return def
	}
	if s, ok := v.(string); ok && s == "" {
		return def
	}
	return v
}

func firstN(items []any, n int) []any {
	if len(items) > n {
		return items[:n]
	}
	return items
}

func round1(v float64) float64 {
	return roundN(v, 1)
}

func round3(v float64) float64 {
	return roundN(v, 3)
}

func roundN(v float64, places int) float64 {
	mult := 1.0
	for i := 0; i < places; i++ {
		mult *= 10
	}
	sign := 1.0
	if v < 0 {
		sign = -1.0
	}
	return float64(int64(v*mult+sign*0.5)) / mult
}
