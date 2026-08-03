# glab — the GitLab CLI, re-pinned onto this repo's update cadence.
# Our pin sits at 1.110.0; the nixpkgs pin ships 1.86.0.
#
# NOT THE `gh` SHAPE, despite being the sibling tool and also a Go
# package. `overlays/dev-tools/gh.nix` lets `mkUpdateScript` prefetch its
# src hash, which is only correct when `src` is a plain fetch of a URL.
# nixpkgs' glab fetches with `leaveDotGit = true` and a `postFetch` that
# records the short commit into `COMMIT` and then strips `.git`, so the
# recorded hash is over the POST-`postFetch` tree — a
# `nix-prefetch-url --unpack` of the repo-archive tarball cannot
# reproduce it, and recording that value would put a plausible, WRONG
# hash in the sidecar. This is the shape `overlays/generic/bruno.nix`
# documents: `platforms = {}` records the version alone and
# `vu.mkGoSrcVendorFix` restores `srcHash` then `vendorHash` as
# `extraExtract` immediately afterwards. Both reads below are therefore
# `sources.<key> or lib.fakeHash` — the `or` covers exactly that window.
#
# THE SRC IS RE-POINTED, NOT RESTATED. `pkgs.glab.src` is
# `fetchFromGitLab`'s own `lib.makeOverridable`, so overriding `tag` +
# `hash` keeps `owner`, `repo`, `leaveDotGit` and — critically —
# `postFetch`. That is what keeps `COMMIT` on disk for upstream's
# `preBuild` (`ldflags+=" -X main.commit=$(cat COMMIT)"`) to read.
# nixpkgs passes `tag` (the fetcher asserts exactly one of `rev`/`tag`),
# so only `tag` is overridden.
#
# `overrideAttrs`, NOT `.override` — the opposite of bruno, and for a
# reason that is structural rather than stylistic. bruno's
# `buildNpmPackage` is a `lib.extendMkDerivation` whose `extendDrvArgs`
# consumes `npmDepsHash` from the INCOMING args, which makes an
# `overrideAttrs`-injected hash inert. `buildGoModule` reads `vendorHash`
# and `src` off `finalAttrs`, so composing on the output is correct here.
# `overlays/dev-tools/gh.nix` is the standing proof for a Go package.
#
# No Go toolchain override. nixpkgs owns this derivation's builder and
# ships a `go` that satisfies gitlab-org/cli's go.mod. If a future
# release raises the floor past our pin the build fails loudly with go's
# own "go.mod requires go >= X", and the fix is the
# `vu.goToolchainForFloor` seam that generic/gluetun.nix and
# generic/oh-my-posh.nix already carry.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (MIT). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs
  # pin, never the consumer's `final`. `final.stdenv.hostPlatform.system`
  # is the only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) lib runCommand writeText;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./glab-sources.json);
  inherit (sources) version;

  # Bound once: passed to BOTH the hash fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = "overlays/dev-tools/glab-sources.json";

  fixHashes = vu.mkGoSrcVendorFix {
    attr = "glab";
    pkgs = ourPkgs;
    pname = "glab";
    inherit sourcesFile;
  };

  # ── The package ──────────────────────────────────────────────────
  # Split in two so the schema extract below can read `.src` and
  # `.goModules` without the exported attribute referring to a
  # derivation that refers back to it. `passthru` is not a derivation
  # input, so the second `overrideAttrs` does not move the store path.
  glabBase = ourPkgs.glab.overrideAttrs (prev: {
    inherit version;

    src = prev.src.override {
      tag = "v${version}";
      hash = sources.srcHash or lib.fakeHash;
    };

    vendorHash = sources.vendorHash or lib.fakeHash;

    # Merge, never replace: buildGoModule hangs `goModules` and
    # `overrideModAttrs` here, module.nix warns loudly when an overlay
    # drops them, and `fixHashes` builds `.goModules` through this very
    # attrset. See the nix-standards fragment.
    passthru =
      (prev.passthru or {})
      // {
        inherit fixHashes;
        updateScript = vu.mkUpdateScript {
          # ORDER IS FORCED, and this is the only extracted package where
          # that is true. `fixHashes` must land FIRST: until it has
          # written the real `srcHash` and `vendorHash`, the sidecar still
          # holds `lib.fakeHash`, and the extract below builds
          # `glabBase.src` and `glabBase.goModules` — so it would fail on
          # the hash mismatch rather than produce a schema. The other
          # three extracted packages fetch a prebuilt binary and have no
          # hash to restore, so they pass `mkExtractRegen` alone.
          extraExtract = ''
            ${fixHashes}
            ${vu.mkExtractRegen {
              attr = "glab";
              dest = "overlays/dev-tools/glab-extracted.json";
              pkgs = ourPkgs;
            }}
          '';
          pkgs = ourPkgs;
          platforms = {};
          pname = "glab";
          inherit sourcesFile;
          versionCheck.cmd = vu.glLatestVersionCmd {
            pkgs = ourPkgs;
            # URL-encoded project path — the `/` MUST be `%2F`.
            project = "gitlab-org%2Fcli";
          };
        };
      };
  });

  # ── Config-key schema extract ────────────────────────────────────
  # `internal/config.KeySchema` is upstream's declared single source of
  # truth for every config key glab understands — it drives
  # NewBlankConfig, KnownKeys, defaultFor, ConfigKeyEquivalence and
  # EnvKeyEquivalence. The HM/devenv modules generate their typed
  # settings options from the committed sidecar this produces, so the
  # option surface is EXTRACTED rather than hand-curated.
  #
  # Curation would get it wrong, and not in a subtle way: the env-var
  # name for a key is `EnvVars` when set and `strings.ToUpper(name)`
  # otherwise, and several keys override it — `telemetry` resolves to
  # GLAB_SEND_TELEMETRY, `host` to GITLAB_HOST/GITLAB_URI/GL_HOST,
  # `remote_alias` to five separate names. The dump calls the exported
  # `EnvKeyEquivalence` rather than reading the raw `EnvVars` field, so
  # the recorded list is the EFFECTIVE resolution order including that
  # uppercase fallback.
  #
  # `EnvKeyEquivalence` layers CI-autologin overrides on top when
  # GLAB_ENABLE_CI_AUTOLOGIN and GITLAB_CI are BOTH "true". Neither is
  # set in a Nix build sandbox, so the schema path is what gets recorded.
  schemaDumpSrc = writeText "glab-schema-dump.go" ''
    package main

    import (
    	"encoding/json"
    	"os"
    	"sort"

    	"gitlab.com/gitlab-org/cli/internal/config"
    )

    type key struct {
    	Name         string   `json:"name"`
    	Scope        string   `json:"scope"`
    	Type         string   `json:"type"`
    	Default      string   `json:"default"`
    	Description  string   `json:"description"`
    	EnvVars      []string `json:"envVars"`
    	UserSettable bool     `json:"userSettable"`
    	Keyring      bool     `json:"keyring"`
    	Fallback     bool     `json:"fallback"`
    }

    func main() {
    	scopes := map[config.Scope]string{
    		config.ScopeGlobal:  "global",
    		config.ScopePerHost: "per-host",
    	}
    	types := map[config.ValueType]string{
    		config.TypeString: "string",
    		config.TypeBool:   "bool",
    		config.TypeList:   "list",
    	}

    	out := make([]key, 0, len(config.KeySchema))
    	for _, kd := range config.KeySchema {
    		// Panic rather than emit a placeholder: a new Scope or
    		// ValueType constant upstream is exactly the kind of shape
    		// change that must fail the build loudly instead of being
    		// silently recorded as the new truth.
    		scope, ok := scopes[kd.Scope]
    		if !ok {
    			panic("glab-schema-dump: unknown Scope for key " + kd.Name)
    		}
    		typ, ok := types[kd.Type]
    		if !ok {
    			panic("glab-schema-dump: unknown ValueType for key " + kd.Name)
    		}
    		out = append(out, key{
    			Name:         kd.Name,
    			Scope:        scope,
    			Type:         typ,
    			Default:      kd.Default,
    			Description:  kd.Description,
    			EnvVars:      config.EnvKeyEquivalence(kd.Name),
    			UserSettable: kd.UserSettable,
    			Keyring:      kd.Keyring,
    			Fallback:     kd.Fallback,
    		})
    	}
    	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })

    	enc := json.NewEncoder(os.Stdout)
    	enc.SetIndent("", "  ")
    	if err := enc.Encode(out); err != nil {
    		panic(err)
    	}
    }
  '';

  # Reuses `glabBase.goModules` as the vendor tree instead of running a
  # second `buildGoModule`. A `buildGoModule` for the dump program would
  # need its OWN vendorHash: `postPatch` is an input to `goModules`, so
  # adding the program through one forks the vendor derivation and puts a
  # third hash in the sidecar for no benefit. The dump imports only
  # stdlib plus an internal package, so the existing vendor tree already
  # satisfies it.
  extracted =
    runCommand "glab-extracted.json" {
      nativeBuildInputs = [ourPkgs.go ourPkgs.jq];
    } ''
      export HOME="$TMPDIR"
      export GOCACHE="$TMPDIR/go-cache"
      export GOPROXY=off
      export GOFLAGS=-mod=vendor
      export GOTOOLCHAIN=local
      # No C toolchain in this derivation's inputs, and none is needed:
      # the dump imports stdlib plus `internal/config`, which is pure Go.
      # Without this, `runtime/cgo` is pulled in and the build dies on a
      # missing gcc rather than on anything meaningful.
      export CGO_ENABLED=0

      cp -r --no-preserve=mode,ownership ${glabBase.src} src
      cd src
      cp -r --no-preserve=mode,ownership ${glabBase.goModules} vendor

      mkdir -p cmd/glab-schema-dump
      cp ${schemaDumpSrc} cmd/glab-schema-dump/main.go

      go run ./cmd/glab-schema-dump > schema.json

      # ── Shape guards ──────────────────────────────────────────────
      # NOT a non-empty guard. The UPDATE PIPELINE regenerates this
      # sidecar inside the same version-bump PR (`extraExtract` above,
      # via `vu.mkExtractRegen`), so an extract that has gone wrong is
      # simply committed as the new truth and the drift check goes green
      # over it. These assert the SHAPE of what was captured; when a key
      # or a field is added, its assertion is added with it.
      fail() {
        echo "glab-extract: $1" >&2
        exit 1
      }

      count=$(jq 'length' schema.json)
      [ "$count" -ge 30 ] || fail "only $count keys captured (expected >= 30; upstream restructured KeySchema)"

      for scope in global per-host; do
        jq -e --arg s "$scope" 'any(.[]; .scope == $s)' schema.json >/dev/null \
          || fail "no keys in scope '$scope' (upstream changed the Scope enum)"
      done

      for k in git_protocol host token; do
        jq -e --arg k "$k" 'any(.[]; .name == $k)' schema.json >/dev/null \
          || fail "key '$k' missing (upstream renamed or removed it)"
      done

      # Every key must resolve to at least one env var, because that is
      # the entire delivery mechanism the HM/devenv modules rely on.
      # EnvKeyEquivalence falls back to the uppercased name, so an empty
      # list means the resolver itself changed shape.
      jq -e 'all(.[]; (.envVars | length) > 0)' schema.json >/dev/null \
        || fail "some keys resolved to no env vars (EnvKeyEquivalence changed shape)"

      # Spot-check the overrides a curated list would have gotten wrong.
      jq -e 'any(.[]; .name == "host" and (.envVars | index("GITLAB_HOST")))' schema.json >/dev/null \
        || fail "host no longer resolves GITLAB_HOST"
      jq -e 'any(.[]; .name == "token" and (.envVars | index("GITLAB_TOKEN")))' schema.json >/dev/null \
        || fail "token no longer resolves GITLAB_TOKEN"
      jq -e 'any(.[]; .name == "telemetry" and (.envVars | index("GLAB_SEND_TELEMETRY")))' schema.json >/dev/null \
        || fail "telemetry no longer resolves GLAB_SEND_TELEMETRY"

      cp schema.json "$out"
    '';
in
  glabBase.overrideAttrs (prev: {
    passthru = (prev.passthru or {}) // {inherit extracted;};
  })
