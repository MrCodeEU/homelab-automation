// Port of scripts/build_deploy_status.py's parse_failed_services and
// service_list.
package deploystatus

import (
	"regexp"
	"strings"
)

var taskRe = regexp.MustCompile(`TASK \[(?:[^:]+ : )?(.*?)\]`)

var whitespaceRe = regexp.MustCompile(`\s+`)

var openvoxErrorRe = regexp.MustCompile(`(?:^|\]\s)Error:\s`)

var openvoxServiceResourceRe = regexp.MustCompile(`(?i)Roles::Services::Service\[([A-Za-z0-9][A-Za-z0-9._-]*)\]`)

var openvoxServiceExecRe = regexp.MustCompile(`(?i)Exec\[services-([A-Za-z0-9][A-Za-z0-9._-]*)-(?:deploy|healthcheck|post-deploy-hook)\]`)

// ParseFailedServices extracts service-level failures from combined deployment
// logs. It keeps the legacy Ansible markers so old retained logs remain
// readable, and recognises OpenVox's Error: resource paths emitted by puppet
// apply. Host-prefixed lines (for example, "[nuc] Error: ...") are supported.
func ParseFailedServices(logLines []string, services []map[string]any) map[string]string {
	failed := map[string]string{}
	var currentTaskServices []string

	for _, line := range logLines {
		if m := taskRe.FindStringSubmatch(line); m != nil {
			taskName := strings.ToLower(m[1])
			currentTaskServices = nil
			for _, service := range services {
				name := strings.ToLower(str(service, "name"))
				if name != "" && strings.Contains(taskName, name) {
					currentTaskServices = append(currentTaskServices, str(service, "name"))
				}
			}
		}

		if strings.Contains(line, "fatal:") || strings.Contains(line, "failed:") || strings.Contains(line, "FAILED!") {
			errMsg := whitespaceRe.ReplaceAllString(strings.TrimSpace(line), " ")
			errMsg = truncate(errMsg, 200)

			for _, name := range currentTaskServices {
				if _, exists := failed[name]; !exists {
					failed[name] = errMsg
				}
			}
			for _, service := range services {
				name := str(service, "name")
				if name != "" && strings.Contains(strings.ToLower(line), strings.ToLower(name)) {
					if _, exists := failed[name]; !exists {
						failed[name] = errMsg
					}
				}
			}
		}

		if openvoxErrorRe.MatchString(line) {
			errMsg := whitespaceRe.ReplaceAllString(strings.TrimSpace(line), " ")
			errMsg = truncate(errMsg, 200)

			for _, match := range openvoxServiceResourceRe.FindAllStringSubmatch(line, -1) {
				markFailedService(failed, services, match[1], errMsg)
			}
			for _, match := range openvoxServiceExecRe.FindAllStringSubmatch(line, -1) {
				markFailedService(failed, services, match[1], errMsg)
			}
		}
	}

	return failed
}

// markFailedService resolves an OpenVox resource title against the canonical
// catalog name, preserving its spelling for the status-page JSON. First error
// wins because later Puppet lines are usually cascaded/skipped consequences.
func markFailedService(failed map[string]string, services []map[string]any, candidate, errMsg string) {
	for _, service := range services {
		name := str(service, "name")
		if name == "" || !strings.EqualFold(name, candidate) {
			continue
		}
		if _, exists := failed[name]; !exists {
			failed[name] = errMsg
		}
		return
	}
}

// ServiceList ports build_deploy_status.py's service_list().
func ServiceList(services []map[string]any) []map[string]any {
	var result []map[string]any
	for _, service := range services {
		enabled, has := service["enabled"]
		if has {
			if b, ok := enabled.(bool); ok && !b {
				continue
			}
		}
		result = append(result, map[string]any{
			"name":        service["name"],
			"domain":      domainOrNil(service),
			"port":        service["port"],
			"host":        service["host"],
			"description": orDefault(str(service, "description"), ""),
			"icon":        orDefault(str(service, "icon"), ""),
			"enabled":     true,
			"managed":     managedOrTrue(service),
		})
	}
	if result == nil {
		result = []map[string]any{}
	}
	return result
}

func domainOrNil(service map[string]any) any {
	d := domainOf(service)
	if d == "" {
		if _, hadDomain := service["domain"]; !hadDomain {
			return nil
		}
	}
	if d == "" {
		return nil
	}
	return d
}

func managedOrTrue(service map[string]any) any {
	if v, ok := service["managed"]; ok {
		return v
	}
	return true
}
