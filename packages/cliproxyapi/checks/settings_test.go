// Copied into a copy of CLIProxyAPI's internal/config by the
// cliproxyapi-settings check (lib/extracted's goTest); it is not part of
// CLIProxyAPI.
//
// TestNatLoad loads nat_config.yaml, the render of a settings sample with each
// secret placeholder replaced as a launcher replaces it, through LoadConfig
// twice: the first load hashes the management key and writes the file back,
// the second reads that rewrite, as a restart does.
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNatLoad(t *testing.T) {
	data, err := os.ReadFile("nat_config.yaml")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	for load := 1; load <= 2; load++ {
		cfg, err := LoadConfig(path)
		if err != nil {
			t.Fatalf("load %d: %v", load, err)
		}
		// A secret with JSON escapes in it reads back verbatim.
		if want := os.Getenv("NAT_PROXY_URL"); cfg.ProxyURL != want {
			t.Fatalf("load %d: requests.proxy-url is %q, want %q", load, cfg.ProxyURL, want)
		}
	}
}
