// provision-syncthing provisions the Ugreen Syncthing node against the
// existing NAS-hub cluster. Idempotent: safe to re-run on every deploy.
// Only creates what's missing; never removes a device or folder.
//
// Port of services/syncthing-ugreen/hooks/provision-syncthing.py - see that
// file's docstring for the full rationale (archive folders, device fan-out).
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	localURL       = "http://127.0.0.1:8384"
	localConfigXML = "/volume1/homelab/syncthing/config/config.xml"
	localDataRoot  = "/var/syncthing"
)

// Archive folders that exist as directories on the NAS today but were never
// registered with Syncthing. Path is relative to the NAS's /data1 (which is
// /mnt/user/Sync on the host) and reused verbatim as the leaf directory name
// on ugreen too, so the same folder looks the same from either side.
var newArchiveFolders = []string{
	"1_2021WS", "2_2022SS", "3_2022WS", "4_2023SS", "5_2023WS", "6_2024SS",
	"Home Assistant", "Mail",
}

var excludedLabels = map[string]bool{"Games": true}

var httpClient = &http.Client{Timeout: 30 * time.Second}

// api mirrors the Python original's dict-in/dict-out shape: bodies and
// responses are untyped maps, so a PUT that started as a GET response
// round-trips every field Syncthing sent back - not just the ones this
// script happens to read - the same way Python's json.load/dump does.
func api(baseURL, apiKey, method, path string, body any) (map[string]any, error) {
	var reqBody io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reqBody = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, strings.TrimRight(baseURL, "/")+path, reqBody)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-API-Key", apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("%s %s -> %d: %s", method, path, resp.StatusCode, string(raw))
	}
	if len(raw) == 0 {
		return nil, nil
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

var apikeyRe = regexp.MustCompile(`<apikey>([^<]+)</apikey>`)

func localAPIKey() (string, error) {
	content, err := os.ReadFile(localConfigXML)
	if err != nil {
		return "", err
	}
	m := apikeyRe.FindSubmatch(content)
	if m == nil {
		return "", fmt.Errorf("could not read API key from %s", localConfigXML)
	}
	return string(m[1]), nil
}

func str(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func list(m map[string]any, key string) []any {
	l, _ := m[key].([]any)
	return l
}

func archiveFolderID(name string) string {
	return "archive-" + strings.ToLower(strings.ReplaceAll(name, " ", "-"))
}

func deviceIDsOf(folder map[string]any) []string {
	var ids []string
	for _, d := range list(folder, "devices") {
		if dm, ok := d.(map[string]any); ok {
			ids = append(ids, str(dm, "deviceID"))
		}
	}
	return ids
}

func hasDevice(folder map[string]any, deviceID string) bool {
	for _, id := range deviceIDsOf(folder) {
		if id == deviceID {
			return true
		}
	}
	return false
}

func labelOr(folder map[string]any, fallbackID string) string {
	if l := str(folder, "label"); l != "" {
		return l
	}
	return fallbackID
}

func run() error {
	nasURL := os.Getenv("NAS_SYNCTHING_URL")
	if nasURL == "" {
		return fmt.Errorf("NAS_SYNCTHING_URL not set")
	}
	nasKey := os.Getenv("NAS_SYNCTHING_API_KEY")
	if nasKey == "" {
		return fmt.Errorf("NAS_SYNCTHING_API_KEY not set")
	}
	localKey, err := localAPIKey()
	if err != nil {
		return err
	}

	localStatus, err := api(localURL, localKey, "GET", "/rest/system/status", nil)
	if err != nil {
		return err
	}
	localDeviceID := str(localStatus, "myID")
	fmt.Printf("ugreen device ID: %s\n", localDeviceID)

	nasConfig, err := api(nasURL, nasKey, "GET", "/rest/config", nil)
	if err != nil {
		return err
	}
	nasStatus, err := api(nasURL, nasKey, "GET", "/rest/system/status", nil)
	if err != nil {
		return err
	}
	nasDeviceID := str(nasStatus, "myID")

	existingDevices := map[string]bool{}
	for _, d := range list(nasConfig, "devices") {
		dm := d.(map[string]any)
		existingDevices[str(dm, "deviceID")] = true
	}
	existingFolders := map[string]bool{}
	for _, f := range list(nasConfig, "folders") {
		fm := f.(map[string]any)
		existingFolders[str(fm, "id")] = true
	}

	// --- 1. NAS side: register ugreen as a device -------------------------
	if !existingDevices[localDeviceID] {
		fmt.Println("registering ugreen as a device on the NAS")
		if _, err := api(nasURL, nasKey, "PUT", "/rest/config/devices/"+localDeviceID, map[string]any{
			"deviceID": localDeviceID, "name": "ugreen",
		}); err != nil {
			return err
		}
	} else {
		fmt.Println("ugreen already known to the NAS")
	}

	// --- 2. NAS side: create the 8 archive folders if missing -------------
	for _, name := range newArchiveFolders {
		fid := archiveFolderID(name)
		if existingFolders[fid] {
			fmt.Printf("archive folder already exists: %s\n", name)
			continue
		}
		fmt.Printf("creating archive folder on the NAS: %s\n", name)
		if _, err := api(nasURL, nasKey, "PUT", "/rest/config/folders/"+fid, map[string]any{
			"id":    fid,
			"label": name,
			"path":  "/data1/" + name,
			"type":  "sendreceive",
			"devices": []map[string]any{
				{"deviceID": nasDeviceID},
				{"deviceID": localDeviceID},
			},
		}); err != nil {
			return err
		}
	}

	// --- 3. NAS side: add ugreen to every existing non-Games folder -------
	for _, f := range list(nasConfig, "folders") {
		folder := f.(map[string]any)
		if excludedLabels[str(folder, "label")] {
			continue
		}
		if hasDevice(folder, localDeviceID) {
			continue
		}
		fmt.Printf("adding ugreen to existing folder: %s\n", labelOr(folder, str(folder, "id")))
		devices := list(folder, "devices")
		folder["devices"] = append(devices, map[string]any{"deviceID": localDeviceID})
		if _, err := api(nasURL, nasKey, "PUT", "/rest/config/folders/"+str(folder, "id"), folder); err != nil {
			return err
		}
	}

	// Re-read: folder devices/paths are now authoritative for what ugreen
	// should mirror, including the archive folders just created above.
	nasConfig, err = api(nasURL, nasKey, "GET", "/rest/config", nil)
	if err != nil {
		return err
	}
	nasDevicesByID := map[string]map[string]any{}
	for _, d := range list(nasConfig, "devices") {
		dm := d.(map[string]any)
		nasDevicesByID[str(dm, "deviceID")] = dm
	}

	// --- 4. ugreen side: register every device the NAS knows about --------
	localConfig, err := api(localURL, localKey, "GET", "/rest/config", nil)
	if err != nil {
		return err
	}
	localExistingDevices := map[string]bool{}
	for _, d := range list(localConfig, "devices") {
		dm := d.(map[string]any)
		localExistingDevices[str(dm, "deviceID")] = true
	}
	for deviceID, dev := range nasDevicesByID {
		if deviceID == localDeviceID || localExistingDevices[deviceID] {
			continue
		}
		name := str(dev, "name")
		if name == "" {
			name = shortID(deviceID)
		}
		fmt.Printf("registering device on ugreen: %s\n", name)
		if _, err := api(localURL, localKey, "PUT", "/rest/config/devices/"+deviceID, map[string]any{
			"deviceID": deviceID, "name": name,
		}); err != nil {
			return err
		}
	}

	// --- 5. ugreen side: accept every folder it was added to --------------
	localConfig, err = api(localURL, localKey, "GET", "/rest/config", nil)
	if err != nil {
		return err
	}
	localExistingFolders := map[string]bool{}
	for _, f := range list(localConfig, "folders") {
		fm := f.(map[string]any)
		localExistingFolders[str(fm, "id")] = true
	}
	for _, f := range list(nasConfig, "folders") {
		folder := f.(map[string]any)
		if excludedLabels[str(folder, "label")] {
			continue
		}
		if !hasDevice(folder, localDeviceID) {
			continue
		}
		fid := str(folder, "id")
		if localExistingFolders[fid] {
			continue
		}
		parts := strings.Split(str(folder, "path"), "/")
		leaf := parts[len(parts)-1]
		fmt.Printf("accepting folder on ugreen: %s\n", labelOr(folder, fid))
		deviceIDs := deviceIDsOf(folder)
		devs := make([]map[string]any, len(deviceIDs))
		for i, id := range deviceIDs {
			devs[i] = map[string]any{"deviceID": id}
		}
		if _, err := api(localURL, localKey, "PUT", "/rest/config/folders/"+fid, map[string]any{
			"id":      fid,
			"label":   labelOr(folder, fid),
			"path":    localDataRoot + "/" + leaf,
			"type":    "sendreceive",
			"devices": devs,
		}); err != nil {
			return err
		}
	}

	fmt.Println("done")
	return nil
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
