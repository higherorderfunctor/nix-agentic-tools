# Human-reviewed disposition for every vocabulary currently emitted by
# overlays/chatgpt-codex-extracted.json. This is deliberately separate from the
# generated sidecar: an update may regenerate facts, but it must not decide how
# Nix should own a new upstream surface. checks/chatgpt-codex-coverage.nix keeps
# every categorical union exact, so an upstream command, flag, field, or
# maturity cannot slip through merely because extraction itself stayed green.
{
  cli = {
    commandFields = {
      aliases = "provenance only; aliases are invocation syntax, not durable configuration";
      flags = "classified exhaustively by canonical long name below";
      help = "provenance only; retained so reviewers can classify new commands and flags";
      path = "identity used by the exact command disposition below";
    };

    commands = {
      # Native config writers whose durable result has an equivalent Nix
      # surface. Nix emits the destination state directly and never shells out
      # to these imperative writers.
      declarativeConfigurationWriters = [
        "codex features disable"
        "codex features enable"
        "codex mcp add"
        "codex mcp remove"
      ];

      # Protocol servers, schema/code generators, diagnostics, and completion
      # output are tools the installed package exposes to callers. They do not
      # describe persistent module state, so the factory installs the binary
      # without inventing one Nix option per operation.
      developerTooling = [
        "codex app-server"
        "codex app-server daemon"
        "codex app-server daemon bootstrap"
        "codex app-server daemon disable-remote-control"
        "codex app-server daemon enable-remote-control"
        "codex app-server daemon restart"
        "codex app-server daemon start"
        "codex app-server daemon stop"
        "codex app-server daemon version"
        "codex app-server generate-json-schema"
        "codex app-server generate-ts"
        "codex app-server proxy"
        "codex completion"
        "codex debug"
        "codex debug app-server"
        "codex debug app-server send-message-v2"
        "codex debug models"
        "codex debug prompt-input"
        "codex exec-server"
        "codex mcp-server"
      ];

      # Codex is installed from the pinned Nix package. Letting its self-update
      # command mutate that immutable output would bypass the overlay/update
      # pipeline and could not survive the next generation.
      nixOwnedPackageLifecycle = [
        "codex update"
      ];

      # Credentials, remote jobs, conversations, plugin marketplaces, and
      # service processes are mutable/account-bound runtime state. Nix may
      # configure their policy inputs, but must not replay these operations or
      # synthesize their databases.
      runtimeOwnedState = [
        "codex archive"
        "codex cloud"
        "codex cloud apply"
        "codex cloud diff"
        "codex cloud exec"
        "codex cloud list"
        "codex cloud status"
        "codex delete"
        "codex login"
        "codex login status"
        "codex logout"
        "codex mcp login"
        "codex mcp logout"
        "codex plugin"
        "codex plugin add"
        "codex plugin list"
        "codex plugin marketplace"
        "codex plugin marketplace add"
        "codex plugin marketplace list"
        "codex plugin marketplace remove"
        "codex plugin marketplace upgrade"
        "codex plugin remove"
        "codex remote-control"
        "codex remote-control pair"
        "codex remote-control start"
        "codex remote-control stop"
        "codex unarchive"
      ];

      # Interactive and non-interactive invocations select a task, session, or
      # one-shot override. Persisting the operation itself would duplicate CLI
      # precedence and turn ephemeral inputs into surprising defaults.
      sessionOperations = [
        "codex"
        "codex apply"
        "codex doctor"
        "codex exec"
        "codex exec resume"
        "codex exec review"
        "codex features"
        "codex features list"
        "codex fork"
        "codex mcp"
        "codex mcp get"
        "codex mcp list"
        "codex resume"
        "codex review"
        "codex sandbox"
      ];
    };

    flagFields = {
      acceptedValues = "closed values feed typed options when the flag represents durable configuration; otherwise they remain invocation provenance";
      conflicts = "invocation parser provenance; Nix assertions model only conflicts between persisted settings";
      default = "invocation default provenance; Nix does not persist CLI defaults";
      help = "review evidence for the canonical flag disposition";
      names = "the first, canonical long name is classified exhaustively below; aliases remain CLI syntax";
      valueName = "invocation operand provenance, not a separate configuration key";
    };

    flags = {
      # These flags expose durable semantics represented by typed/freeform
      # settings, named profiles, permission profiles, feature toggles, or MCP
      # records. Dedicated typed enums consume extracted values where the CLI
      # publishes a closed set; the flag itself remains invocation-only.
      declarativeEquivalent = [
        "--ask-for-approval"
        "--bearer-token-env-var"
        "--config"
        "--disable"
        "--enable"
        "--local-provider"
        "--model"
        "--oauth-client-id"
        "--oauth-resource"
        "--oss"
        "--permission-profile"
        "--profile"
        "--sandbox"
        "--scopes"
        "--search"
        "--url"
      ];

      # App/exec-server transport, generated-schema, and sandbox diagnostic
      # controls configure one protocol process or generated artifact, not the
      # durable Codex user/project configuration managed by this factory.
      developerTooling = [
        "--analytics-default-enabled"
        "--code-mode-host"
        "--environment-id"
        "--experimental"
        "--listen"
        "--name"
        "--out"
        "--prettier"
        "--remote-control"
        "--sandbox-state-disable-network"
        "--sandbox-state-json"
        "--sandbox-state-readable-root"
        "--sock"
        "--stdio"
        "--use-agent-identity-auth"
        "--ws-audience"
        "--ws-auth"
        "--ws-issuer"
        "--ws-max-clock-skew-seconds"
        "--ws-shared-secret-file"
        "--ws-token-file"
        "--ws-token-sha256"
      ];

      # Auth inputs and plugin/marketplace selectors accompany native mutable
      # state. Store-backed declarative files must never capture their token
      # values or pretend to own installation/authentication databases.
      runtimeOwnedState = [
        "--available"
        "--device-auth"
        "--marketplace"
        "--ref"
        "--sparse"
        "--with-access-token"
        "--with-api-key"
      ];

      # Task selection, IO paths, output formatting, dangerous bypasses, and
      # other one-shot controls stay on the invocation. Some names such as
      # --env are context-dependent across commands; that is further reason
      # not to assign them one persistent config meaning.
      sessionOnly = [
        "--add-dir"
        "--all"
        "--ascii"
        "--attempt"
        "--attempts"
        "--base"
        "--branch"
        "--bundled"
        "--cd"
        "--color"
        "--commit"
        "--cursor"
        "--dangerously-bypass-approvals-and-sandbox"
        "--dangerously-bypass-hook-trust"
        "--env"
        "--ephemeral"
        "--force"
        "--help"
        "--ignore-rules"
        "--ignore-user-config"
        "--image"
        "--include-managed-config"
        "--include-non-interactive"
        "--json"
        "--last"
        "--limit"
        "--no-alt-screen"
        "--no-color"
        "--output-last-message"
        "--output-schema"
        "--remote"
        "--remote-auth-token-env"
        "--skip-git-repo-check"
        "--strict-config"
        "--summary"
        "--title"
        "--uncommitted"
        "--version"
      ];
    };
  };

  # Codex currently exposes no config.toml schema. Both arrays must stay empty;
  # any future extractor that populates one fails the coverage check until each
  # key receives a typed/freeform/materialized/omitted disposition.
  config = {
    documentedKeys = "empty unsupported extraction seam; manual-documented keys use typed/freeform TOML and the CX-012 ledger";
    probeValidatedKeys = "empty unsupported extraction seam; behavioral probes live in codex-configuration-probes.md";
  };

  features = {
    fields = {
      default = "provenance only; omitting a Nix leaf preserves the pinned binary's native default";
      maturity = "routes stable names to typed options and every other maturity to the boolean freeform escape hatch";
      name = "stable names become typed ai.codex.settings.features keys; all names remain accepted by the freeform boolean table";
    };
    maturities = {
      deprecated = "freeform only; never advertise deprecated toggles as first-class options";
      experimental = "freeform only; opt-in without freezing an unstable vocabulary";
      removed = "provenance only; never resurrect removed behavior as a typed option";
      stable = "typed dynamically from the extracted names";
      "under development" = "freeform only; forward-compatible but deliberately unadvertised";
    };
  };

  models = {
    defaultReasoningLevel = "provenance only; Codex chooses the native per-model default when no Nix setting is declared";
    displayName = "provenance only; presentation text is not configuration";
    reasoningLevels = "union supplies the typed model_reasoning_effort and subagent-reasoning enums";
    slug = "soft hint only; model remains a string because account, provider, and rollout availability is dynamic";
  };

  provenance = {
    codexVersion = "binds the audit to the packaged binary version and moves with the generated sidecar";
    extractorSchema = "guards interpretation of this ledger; a schema change requires a human coverage review";
  };
}
