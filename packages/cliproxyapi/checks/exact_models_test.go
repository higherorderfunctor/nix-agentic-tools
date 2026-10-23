// In CPA's executor package: exercise the real request preparation with a
// capture transport. The same rendered switches are checked by the module suite.
package executor

import (
	"context"
	"errors"
	"io"
	"net/http"
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	cliproxyauth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	sdktranslator "github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
	"github.com/tidwall/gjson"
)

func natExactConfig(t *testing.T) *config.Config {
	t.Helper()
	cfg, err := config.LoadConfig("nat_exact_config.json")
	if err != nil {
		t.Fatal("lowered exact-model config did not load")
	}
	return cfg
}

// Return at the HTTP boundary: no network, token refresh or live credentials.
func natExactCapture(t *testing.T, execute func(context.Context)) []byte {
	t.Helper()
	var captured []byte
	transport := roundTripperFunc(func(req *http.Request) (*http.Response, error) {
		var err error
		captured, err = io.ReadAll(req.Body)
		if err != nil {
			t.Fatal("capture could not read request")
		}
		return nil, errors.New("capture complete")
	})
	execute(context.WithValue(t.Context(), "cliproxy.roundtripper", http.RoundTripper(transport)))
	if len(captured) == 0 {
		t.Fatal("executor did not reach capture transport")
	}
	return captured
}

func TestNatExactClaudeNoFallbacks(t *testing.T) {
	for _, disabled := range []bool{true, false} {
		cfg := natExactConfig(t)
		if !cfg.DisableClaudeCloakMode {
			t.Fatal("lowered cloak switch missing")
		}
		cfg.DisableClaudeCloakMode = disabled
		auth := &cliproxyauth.Auth{
			ID: "nat-claude", Provider: "claude",
			Attributes: map[string]string{"api_key": "sk-ant-oat-nat-test", "auth_kind": "oauth"},
			Metadata:   claudeOAuthTestMetadata(),
		}
		if auth.AuthKind() != cliproxyauth.AuthKindOAuth {
			t.Fatal("capture credential must be OAuth")
		}
		body := natExactCapture(t, func(ctx context.Context) {
			_, _ = NewClaudeExecutor(cfg).Execute(ctx, auth, cliproxyexecutor.Request{
				Model: "claude-opus-5-5", Payload: []byte(`{"model":"claude-opus-5-5","messages":[{"role":"user","content":"hello"}],"max_tokens":16}`),
			}, cliproxyexecutor.Options{SourceFormat: sdktranslator.FormatClaude})
		})
		if gjson.GetBytes(body, "fallbacks").Exists() == disabled {
			t.Fatal("cloak switch did not control fallback injection")
		}
	}
}

func TestNatExactCodexNoImageTool(t *testing.T) {
	for _, disabled := range []bool{true, false} {
		cfg := natExactConfig(t)
		if cfg.DisableImageGeneration != config.DisableImageGenerationAll {
			t.Fatal("lowered image switch missing")
		}
		if !disabled {
			cfg.DisableImageGeneration = config.DisableImageGenerationOff
		}
		body := natExactCapture(t, func(ctx context.Context) {
			_, _ = NewCodexExecutor(cfg).Execute(ctx, &cliproxyauth.Auth{ID: "nat-codex", Provider: "codex", Attributes: map[string]string{"api_key": "nat-test"}}, cliproxyexecutor.Request{
				Model: "gpt-5.5", Payload: []byte(`{"model":"gpt-5.5","input":[{"role":"user","content":"hello"}]}`),
			}, cliproxyexecutor.Options{SourceFormat: sdktranslator.FromString("openai-response")})
		})
		image := false
		for _, tool := range gjson.GetBytes(body, "tools").Array() {
			image = image || tool.Get("type").String() == "image_generation"
		}
		if image == disabled {
			t.Fatal("image switch did not control tool injection")
		}
	}
}
