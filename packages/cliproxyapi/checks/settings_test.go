// Copied into CLIProxyAPI's internal/config by the cliproxyapi-settings
// check (lib/extracted's goTest); it is not part of CLIProxyAPI.
// The clean rendered sample passes native v8 validation. Loading a writable
// copy hashes the management key and removes a conflicting legacy proxy key;
// every other document value and the substituted secret survive the rewrite.
package config

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestNatLoad(t *testing.T) {
	data, err := os.ReadFile("nat_config.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateV8Config(data); err != nil {
		t.Fatalf("native v8 validation: %v", err)
	}
	var original map[string]any
	if err := json.Unmarshal(data, &original); err != nil {
		t.Fatal(err)
	}
	server := original["server"].(map[string]any)
	server["nat-unknown"] = "bad"
	bad, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateV8Config(bad); err == nil {
		t.Fatal("native v8 validation accepted unknown server.nat-unknown")
	}
	delete(server, "nat-unknown")

	// LoadConfig accepts legacy input, while v8 management writes forbid it.
	// The v8 requests.proxy-url must win and the legacy key must be removed.
	original["proxy-url"] = "legacy-loser"
	data, err = json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	var hash string
	var rewritten []byte
	for load := 1; load <= 2; load++ {
		cfg, err := LoadConfig(path)
		if err != nil {
			t.Fatalf("load %d: %v", load, err)
		}
		if want := os.Getenv("NAT_PROXY_URL"); cfg.ProxyURL != want {
			t.Fatalf("load %d: requests.proxy-url is %q, want %q", load, cfg.ProxyURL, want)
		}
		if len(cfg.Payload.DefaultRaw) != 1 || len(cfg.Payload.OverrideRaw) != 1 {
			t.Fatalf("load %d: raw payload rules dropped: default=%d override=%d", load, len(cfg.Payload.DefaultRaw), len(cfg.Payload.OverrideRaw))
		}
		if cfg.Payload.DefaultRaw[0].Params["sample"] != "{}" || cfg.Payload.OverrideRaw[0].Params["sample"] != "{}" {
			t.Fatalf("load %d: raw payload params changed", load)
		}
		if cfg.ClaudeHeaderDefaults.ClientRequestID != ClaudeClientRequestIDOn {
			t.Fatalf("load %d: client-request-id changed: %q", load, cfg.ClaudeHeaderDefaults.ClientRequestID)
		}
		after, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if load == 1 {
			var decoded map[string]any
			if err := yaml.Unmarshal(after, &decoded); err != nil {
				t.Fatal(err)
			}
			hash = decoded["management"].(map[string]any)["secret-key"].(string)
			if !looksLikeBcrypt(hash) {
				t.Fatal("rewritten management.secret-key is not a bcrypt hash")
			}
			original["management"].(map[string]any)["secret-key"] = hash
			delete(original, "proxy-url")
			// Normalize YAML numeric representations to JSON before comparing.
			actual, err := json.Marshal(decoded)
			if err != nil {
				t.Fatal(err)
			}
			expected, err := json.Marshal(original)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(actual, expected) {
				t.Fatalf("rewritten document differs beyond hash/legacy removal:\n%s\n%s", actual, expected)
			}
			rewritten = after
		} else if !bytes.Equal(after, rewritten) {
			t.Fatal("second load changed the persisted document")
		}
		if cfg.RemoteManagement.SecretKey != hash {
			t.Fatalf("load %d: management hash differs from persisted value", load)
		}
	}
	t.Log("native v8 validation and unknown-key control passed; raw payload rules retained; persisted bcrypt, legacy removal, other values and substituted secret preserved across reload")
}
