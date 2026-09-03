package collectors

import (
	"encoding/json"
	"testing"
)

func TestCSPViolationLineDecodesWellFormedLine(t *testing.T) {
	line := `{"event":"csp_violation","document_uri":"https://mljr.eu/","directive":"script-src","blocked_uri":"https://evil.example/x.js","source_file":"","disposition":"enforce"}`
	var v cspViolationLine
	if err := json.Unmarshal([]byte(line), &v); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if v.DocumentURI != "https://mljr.eu/" || v.Directive != "script-src" || v.BlockedURI != "https://evil.example/x.js" {
		t.Fatalf("got %+v", v)
	}
}

func TestCSPViolationLineIgnoresGarbage(t *testing.T) {
	var v cspViolationLine
	if err := json.Unmarshal([]byte("not json"), &v); err == nil {
		t.Fatalf("expected an error for garbage input")
	}
}
