// Copied into a copy of CPA Manager Plus's apps/manager-server/internal/config
// by the cpa-manager-plus-settings check (lib/extracted's goTest); it is not
// part of CPA Manager Plus.
//
// TestNatLoad loads nat_config.json, the config.json render of a settings
// sample, with the rendered environment in nat_environment.json set, through
// LoadWithoutCreatingDefault. config.json decoding ignores unknown keys, so
// the file is also decoded into fileConfig with unknown keys refused.
package config

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestNatLoad(t *testing.T) {
	data, err := os.ReadFile("nat_config.json")
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&fileConfig{}); err != nil {
		t.Fatalf("config.json: %v", err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	environment, err := os.ReadFile("nat_environment.json")
	if err != nil {
		t.Fatal(err)
	}
	variables := map[string]string{}
	if err := json.Unmarshal(environment, &variables); err != nil {
		t.Fatal(err)
	}
	for name, value := range variables {
		t.Setenv(name, value)
	}
	t.Setenv(configEnvKey, path)
	cfg, err := LoadWithoutCreatingDefault()
	if err != nil {
		t.Fatal(err)
	}
	// A key-carrying variable reaches the loaded configuration.
	if want := variables["CPA_MANAGEMENT_KEY"]; cfg.ManagementKey != want {
		t.Fatalf("CPA_MANAGEMENT_KEY loads as %q, want %q", cfg.ManagementKey, want)
	}
}
