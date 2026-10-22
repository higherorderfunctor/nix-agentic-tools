package gate

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// policy is the file the gate loads, one entry per client key. A launcher
// renders it with the keys filled in; the gate never reads them elsewhere.
type policy struct {
	Entries []struct {
		Name        string              `json:"name"`
		Key         string              `json:"key"`
		Internal    string              `json:"internal"`
		APIs        []string            `json:"apis"`
		Models      []string            `json:"models"`
		HostedTools map[string][]string `json:"hostedTools"`
	} `json:"entries"`
}

// entry is what the gate keeps of a policy entry. The client key is kept
// only as its SHA-256 digest.
type entry struct {
	name        string
	internal    string
	apis        map[string]bool
	models      map[string]bool
	hostedTools map[string]bool
}

// loadPolicy reads the policy at path and indexes its entries by the SHA-256
// of their client key. Its errors name entries and fields, never values.
func loadPolicy(path string) (map[[sha256.Size]byte]*entry, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("policy: read failed")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	// A field this build does not enforce is refused, not ignored.
	decoder.DisallowUnknownFields()
	var p policy
	if err := decoder.Decode(&p); err != nil {
		return nil, fmt.Errorf("policy: invalid JSON or field")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("policy: trailing data")
	}

	keys := map[[sha256.Size]byte]*entry{}
	internals := map[[sha256.Size]byte]string{}
	for _, pe := range p.Entries {
		switch {
		case pe.Key == "":
			return nil, fmt.Errorf("entry %q: empty client key", pe.Name)
		case pe.Internal == "":
			return nil, fmt.Errorf("entry %q: empty internal key", pe.Name)
		case len(pe.APIs) == 0:
			return nil, fmt.Errorf("entry %q: no apis", pe.Name)
		case len(pe.Models) == 0:
			return nil, fmt.Errorf("entry %q: no models", pe.Name)
		}
		e := &entry{name: pe.Name, internal: pe.Internal, apis: map[string]bool{}, models: map[string]bool{}, hostedTools: map[string]bool{}}
		for _, model := range pe.Models {
			if model == "" {
				return nil, fmt.Errorf("entry %q: empty model", pe.Name)
			}
			e.models[model] = true
		}
		for tool, implied := range pe.HostedTools {
			if tool == "" || tool == "function" || tool == "custom" {
				return nil, fmt.Errorf("entry %q: invalid hosted tool name", pe.Name)
			}
			for _, model := range implied {
				if !e.models[model] {
					return nil, fmt.Errorf("entry %q: hosted tool model outside set", pe.Name)
				}
			}
			e.hostedTools[tool] = true
		}
		for i, api := range pe.APIs {
			if !knownAPI(api) {
				return nil, fmt.Errorf("entry %q: apis[%d] is unknown", pe.Name, i)
			}
			e.apis[api] = true
		}
		sum := sha256.Sum256([]byte(pe.Key))
		if other, ok := keys[sum]; ok {
			return nil, fmt.Errorf("entries %q and %q share a client key", other.name, pe.Name)
		}
		keys[sum] = e
		internals[sha256.Sum256([]byte(pe.Internal))] = pe.Name
	}
	// A client key equal to an internal key would let a client call CPA
	// directly with the key it already holds.
	for sum, name := range internals {
		if e, ok := keys[sum]; ok {
			return nil, fmt.Errorf("entry %q: client key equals the internal key of entry %q", e.name, name)
		}
	}
	return keys, nil
}
