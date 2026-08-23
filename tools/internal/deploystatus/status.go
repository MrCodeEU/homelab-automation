// Port of scripts/build_deploy_status.py's parse_failed_services and
// service_list.
package deploystatus

import (
	"regexp"
	"strings"
)

var taskRe = regexp.MustCompile(`TASK \[(?:[^:]+ : )?(.*?)\]`)

var whitespaceRe = regexp.MustCompile(`\s+`)

// ParseFailedServices ports build_deploy_status.py's regex-based Ansible
// log scraping. Known dead in the OpenVox era - Puppet's own log lines
// (Notice:/Error:) never match these Ansible-shaped markers (TASK [...],
// fatal:, failed:, FAILED!), so this always returns empty against a real
// OpenVox apply log today. Kept as a faithful, unmodified port rather
// than "fixed" as a side effect of the Go rewrite.
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
	}

	return failed
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
