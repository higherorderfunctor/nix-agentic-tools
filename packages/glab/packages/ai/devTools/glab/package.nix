# glab — the GitLab CLI, re-pinned onto this repo's update CADENCE: a
# release lands here on the 4x/day sweep instead of waiting on a nixpkgs
# channel bump. Deliberately no version numbers here — they rot, and the
# size of the gap against nixpkgs is not the justification. The gap is
# often small and sometimes zero; that is expected.
#
# NOT THE `gh` SHAPE, despite being the sibling tool and also a Go
# package. `packages/gh/packages/ai/devTools/gh/package.nix` lets `mkUpdateScript` prefetch its
# src hash, which is only correct when `src` is a plain fetch of a URL.
# nixpkgs' glab fetches with `leaveDotGit = true` and a `postFetch` that
# records the short commit into `COMMIT` and then strips `.git`, so the
# recorded hash is over the POST-`postFetch` tree — a
# `nix-prefetch-url --unpack` of the repo-archive tarball cannot
# reproduce it, and recording that value would put a plausible, WRONG
# hash in the sidecar. This is the shape `packages/bruno/packages/ai/generic/bruno/package.nix`
# documents: `platforms = {}` records the version alone and
# `vu.mkGoUpdateExtract` (with `srcFromSidecar = true`) restores
# `srcHash`, then derives `goFloor`, then restores `vendorHash`, as
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
# BOTH override seams are used, for different things — and they are not
# interchangeable. Sort the attr into INPUT or OUTPUT:
#
#   `vendorHash` / `src` / `version` -> OUTPUT. `buildGoModule` reads
#   these off `finalAttrs`, so composing on the result with
#   `overrideAttrs` is correct. This is the opposite of bruno, whose
#   `buildNpmPackage` is a `lib.extendMkDerivation` consuming
#   `npmDepsHash` from the INCOMING args, which makes an
#   `overrideAttrs`-injected hash inert.
#
#   the Go TOOLCHAIN -> INPUT. It is a builder argument, not an attr, so
#   `overrideAttrs` cannot reach it at all; only `.override` can. That is
#   why the expression below opens with `goToolchain.overridePackage`
#   and THEN composes `overrideAttrs` on the result.
#
# `packages/gh/packages/ai/devTools/gh/package.nix` carries the identical pair.
#
# The toolchain comes from the locked go-overlay (`vu.mkGoToolchain`), never
# from nixpkgs, and the go.mod floor is validated against it. gitlab-org/cli
# has required Go >= 1.26.5 since v1.109.0; a consumer following a nixpkgs
# shipping 1.26.2 used to get `go.mod requires go >= 1.26.5 (running go
# 1.26.2)` with nothing in this repo red. Because the compiler no longer
# depends on nixpkgs, that asymmetry is gone.
#
# Supporting package; its public role is encoded by the native recipe tree.
# earmarked repo split can lift the subtree whole.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) lib runCommand writeText;
  vu = packageLib;

  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
  inherit (sources) version;

  # DERIVED from the pinned source's go.mod by `fixGoFloor` below, never
  # hand-written. See `vu.mkGoFloorFix` for why, and
  # `checks/packaging/go-floor-drift.nix` for the gate that keeps it honest.
  goFloor = sources.goFloor or vu.goFloorUnknown;

  # Bound once and shared: the package builder AND the schema-dump extract
  # below both compile this module's Go, so both need the locked go-overlay
  # toolchain. Giving the extract plain `pkgs.go` would compile it with
  # nixpkgs' Go instead of the builder's.
  goToolchain = vu.mkGoToolchain {
    floor = goFloor;
    inherit pkgs;
    pname = "glab";
  };

  # Bound once: passed to BOTH the hash fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = repoPath ../../../../sources.json;

  # `srcFromSidecar` because glab passes `platforms = {}` to
  # mkUpdateScript (see below): nixpkgs' fetcher carries a `postFetch`,
  # so the prefetch path cannot produce a usable src hash and a fixer has
  # to. That is exactly the case whose correct order — src, THEN floor,
  # THEN vendor — is what `vu.mkGoUpdateExtract` emits.
  #
  # `extraAfter` carries the config-key schema dump, which COMPILES this
  # module's Go against the vendor tree and therefore has to follow both
  # the floor and the vendor fix (for `.goModules`).
  goUpdate = vu.mkGoUpdateExtract {
    attr = "glab";
    extraAfter = vu.mkExtractRegen {
      attr = "glab";
      dest = repoPath ../../../../extracted.json;
      inherit pkgs;
    };
    inherit pkgs;
    pname = "glab";
    srcFromSidecar = true;
    inherit sourcesFile;
  };
  inherit (goUpdate) fixGoFloor fixSrcHash fixVendorHash;

  # ── The package ──────────────────────────────────────────────────
  # Split in two so the schema extract below can read `.src` and
  # `.goModules` without the exported attribute referring to a
  # derivation that refers back to it. `passthru` is not a derivation
  # input, so the second `overrideAttrs` does not move the store path.
  #
  # Other Go packages call `vu.mkGoToolchain` inline. glab binds the result
  # once because it needs the toolchain's `go` a second time, for the
  # schema-dump extract below.
  glabBase =
    (goToolchain.overridePackage pkgs.glab)
  .overrideAttrs (prev: {
      inherit version;

      src = prev.src.override {
        tag = "v${version}";
        hash = sources.srcHash or lib.fakeHash;
      };

      vendorHash = sources.vendorHash or lib.fakeHash;

      # Merge, never replace: buildGoModule hangs `goModules` and
      # `overrideModAttrs` here, module.nix warns loudly when an overlay
      # drops them, and `fixVendorHash` builds `.goModules` through this
      # very attrset. See the nix-standards fragment.
      passthru =
        (prev.passthru or {})
        // {
          inherit fixGoFloor fixSrcHash fixVendorHash goFloor;
          goUpdateExtract = goUpdate.extract;
          updateScript = vu.mkUpdateScript {
            # ORDER IS FORCED and glab is the only package where all
            # four stages are in play, but it is no longer restated
            # here — `vu.mkGoUpdateExtract` owns it, and `goUpdate`
            # above says which axes glab sits on.
            #
            # The order it emits is src -> floor -> vendor -> extract.
            extraExtract = "${goUpdate.extract}";
            inherit pkgs;
            platforms = {};
            pname = "glab";
            inherit sourcesFile;
            versionCheck.cmd = vu.glLatestVersionCmd {
              inherit pkgs;
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
      # The dump must use the package's locked compiler (`goToolchain.go`).
      nativeBuildInputs = [goToolchain.go pkgs.jq];
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
