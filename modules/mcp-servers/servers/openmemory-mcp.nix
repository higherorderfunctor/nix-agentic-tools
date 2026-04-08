{
  lib,
  mcpLib,
  ...
}: let
  inherit (lib) mkOption types optionalAttrs;
in {
  meta = {
    modes = {
      stdio = "openmemory-mcp";
      http = "openmemory-mcp-serve";
    };
    scope = "remote";
    defaultPort = 19758;
    credentialVars = {
      credentials = {
        envVar = "OM_API_KEY";
        required = false;
      };
      openaiCredentials = {
        envVar = "OPENAI_API_KEY";
        required = false;
      };
    };
    tools = ["openmemory_delete" "openmemory_get" "openmemory_list" "openmemory_query" "openmemory_reinforce" "openmemory_store"];
  };

  settingsOptions = {
    credentials = mcpLib.mkCredentialsOption "OM_API_KEY";
    openaiCredentials = mcpLib.mkCredentialsOption "OPENAI_API_KEY";

    path = mkOption {
      type = types.str;
      default = "/mcp";
      description = "HTTP endpoint path. Only used in HTTP mode.";
    };

    # ── Core ──────────────────────────────────────────────────────
    tier = mkOption {
      type = types.enum ["hybrid" "fast" "smart" "deep"];
      default = "hybrid";
      description = "Performance tier. Affects defaults for vector dimensions, cache segments, and active memory limits.";
    };

    telemetry = mkOption {
      type = types.bool;
      default = true;
      description = "Enable anonymous telemetry.";
    };

    useSummaryOnly = mkOption {
      type = types.bool;
      default = true;
      description = "Use only summary for reflection instead of full content.";
    };

    # ── Metadata backend ──────────────────────────────────────────
    metadataBackend = mkOption {
      type = types.attrTag {
        sqlite = mkOption {
          type = types.submodule {
            options.path = mkOption {
              type = types.str;
              default = "./data/openmemory.sqlite";
              description = "SQLite database file path.";
            };
          };
          default = {};
        };
        postgres = mkOption {
          type = types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                default = "localhost";
                description = "PostgreSQL host.";
              };
              port = mkOption {
                type = types.port;
                default = 5432;
                description = "PostgreSQL port.";
              };
              db = mkOption {
                type = types.str;
                default = "openmemory";
                description = "PostgreSQL database name.";
              };
              user = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "PostgreSQL user. Defaults to current system user.";
              };
              password = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "PostgreSQL password. Prefer credentials option for secrets.";
              };
              ssl = mkOption {
                type = types.nullOr (types.enum ["disable" "require"]);
                default = null;
                description = "PostgreSQL SSL mode.";
              };
              schema = mkOption {
                type = types.str;
                default = "public";
                description = "PostgreSQL schema.";
              };
              table = mkOption {
                type = types.str;
                default = "openmemory_memories";
                description = "PostgreSQL memories table name.";
              };
            };
          };
          default = {};
        };
      };
      default.sqlite = {};
      description = "Metadata storage backend. Set exactly one of sqlite or postgres.";
    };

    # ── Vector backend ────────────────────────────────────────────
    vectorBackend = mkOption {
      type = types.attrTag {
        sqlite = mkOption {
          type = types.submodule {
            options.table = mkOption {
              type = types.str;
              default = "vectors";
              description = "SQLite vector table name.";
            };
          };
          default = {};
        };
        postgres = mkOption {
          type = types.submodule {
            options.table = mkOption {
              type = types.str;
              default = "openmemory_vectors";
              description = "PostgreSQL vector table name.";
            };
          };
          default = {};
        };
        valkey = mkOption {
          type = types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                default = "localhost";
                description = "Valkey/Redis host.";
              };
              port = mkOption {
                type = types.port;
                default = 6379;
                description = "Valkey/Redis port.";
              };
              password = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Valkey/Redis password.";
              };
            };
          };
          default = {};
        };
      };
      default.sqlite = {};
      description = "Vector storage backend. Set exactly one of sqlite, postgres, or valkey.";
    };

    # ── Embeddings ────────────────────────────────────────────────
    embeddings = mkOption {
      type = types.attrTag {
        ollama = mkOption {
          type = types.submodule {
            options = {
              url = mkOption {
                type = types.str;
                default = "http://localhost:11434";
                description = "Ollama server URL.";
              };
              model = mkOption {
                type = types.str;
                default = "nomic-embed-text";
                description = "Ollama embedding model.";
              };
            };
          };
          default = {};
        };
        openai = mkOption {
          type = types.submodule {
            options = {
              baseUrl = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "OpenAI base URL override (for compatible APIs).";
              };
              model = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "OpenAI embedding model name.";
              };
            };
          };
          default = {};
        };
        gemini = mkOption {
          type = types.submodule {};
          default = {};
        };
        aws = mkOption {
          type = types.submodule {};
          default = {};
        };
        local = mkOption {
          type = types.submodule {
            options.modelPath = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Path to local embedding model file.";
            };
          };
          default = {};
        };
        synthetic = mkOption {
          type = types.submodule {};
          default = {};
        };
      };
      default.synthetic = {};
      description = "Embedding provider. Set exactly one.";
    };

    mode = mkOption {
      type = types.nullOr (types.enum ["standard"]);
      default = null;
      description = "Server mode. Default: standard.";
    };

    logAuth = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Enable authentication logging.";
    };

    # ── IDE integration ───────────────────────────────────────────
    ideMode = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Enable IDE integration mode.";
    };

    ideAllowedOrigins = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "Allowed CORS origins for IDE mode. Default: localhost:5173, localhost:3000.";
    };

    # ── Vector dimensions ─────────────────────────────────────────
    vecDim = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Vector dimension. Must match the embedding model (e.g., 768 for nomic-embed-text). Auto-detected by tier when null.";
    };

    maxVectorDim = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Maximum allowed vector dimension. Auto-detected by tier when null.";
    };

    minVectorDim = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Minimum allowed vector dimension. Default: 64.";
    };

    # ── Embedding tuning ──────────────────────────────────────────
    embedMode = mkOption {
      type = types.nullOr (types.enum ["simple"]);
      default = null;
      description = "Embedding mode. Default: simple.";
    };

    embedTimeoutMs = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Embedding timeout in milliseconds. Default: 30000.";
    };

    embedDelayMs = mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = "Delay between embedding requests in milliseconds. Default: 200.";
    };

    embedFallback = mkOption {
      type = types.nullOr (types.enum ["synthetic"]);
      default = null;
      description = "Fallback embedding strategy when primary fails. Default: synthetic.";
    };

    advEmbedParallel = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Enable advanced parallel embedding.";
    };

    cacheSegments = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Number of cache segments. Auto-detected by tier when null.";
    };

    # ── Summary ───────────────────────────────────────────────────
    summaryLayers = mkOption {
      type = types.nullOr (types.ints.between 1 3);
      default = null;
      description = "Number of summary layers (1-3). Default: 3.";
    };

    summaryMaxLength = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Maximum summary length in characters. Default: 200.";
    };

    # ── Search & relevance ────────────────────────────────────────
    minScore = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Minimum relevance score threshold. Default: 0.3.";
    };

    keywordBoost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Keyword boost multiplier. Default: 2.5.";
    };

    keywordMinLength = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Minimum keyword length. Default: 3.";
    };

    # ── Segmentation & compression ────────────────────────────────
    segSize = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Segment size. Default: 10000.";
    };

    compression = mkOption {
      type = types.submodule {
        options = {
          enabled = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Enable compression.";
          };
          algorithm = mkOption {
            type = types.nullOr (types.enum ["auto"]);
            default = null;
            description = "Compression algorithm. Default: auto.";
          };
          minLength = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Minimum length to compress. Default: 100.";
          };
        };
      };
      default = {};
      description = "Memory compression configuration.";
    };

    # ── Decay ─────────────────────────────────────────────────────
    decay = mkOption {
      type = types.submodule {
        options = {
          intervalMinutes = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Decay interval in minutes. Default: 1440 (24h).";
          };
          lambda = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Decay lambda parameter. Default: 0.02.";
          };
          ratio = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Decay ratio. Default: 0.03.";
          };
          threads = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Number of decay worker threads. Default: 3.";
          };
          coldThreshold = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Cold memory threshold. Default: 0.25.";
          };
          reinforceOnQuery = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Reinforce decay on query. Default: true.";
          };
          sleepMs = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Sleep interval between decay operations in milliseconds. Default: 200.";
          };
        };
      };
      default = {};
      description = "Memory decay configuration.";
    };

    # ── Reflection & regeneration ─────────────────────────────────
    reflection = mkOption {
      type = types.submodule {
        options = {
          autoReflect = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Enable automatic memory reflection.";
          };
          interval = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Reflection interval (number of operations between reflections). Default: 10.";
          };
          minMemories = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Minimum memories required before reflection triggers. Default: 20.";
          };
          regenerationEnabled = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Enable memory regeneration. Default: true.";
          };
          userSummaryInterval = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "User summary update interval. Default: 30.";
          };
        };
      };
      default = {};
      description = "Memory reflection and regeneration configuration.";
    };

    # ── Rate limiting ─────────────────────────────────────────────
    rateLimit = mkOption {
      type = types.submodule {
        options = {
          enabled = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Enable rate limiting.";
          };
          maxRequests = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Max requests per window. Default: 100.";
          };
          windowMs = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Rate limit window in milliseconds. Default: 60000.";
          };
        };
      };
      default = {};
      description = "Rate limiting configuration.";
    };

    # ── Performance & limits ──────────────────────────────────────
    maxActive = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Maximum active memory items. Auto-detected by tier when null.";
    };

    maxPayloadSize = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Maximum payload size in bytes. Default: 1000000.";
    };

    # ── LangGraph ─────────────────────────────────────────────────
    langGraph = mkOption {
      type = types.submodule {
        options = {
          namespace = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "LangGraph namespace. Default: default.";
          };
          maxContext = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "LangGraph max context. Default: 50.";
          };
          reflective = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Enable LangGraph reflective mode. Default: true.";
          };
        };
      };
      default = {};
      description = "LangGraph integration configuration.";
    };
  };

  settingsToEnv = cfg: mode: let
    s = cfg.settings;
    meta = s.metadataBackend;
    vec = s.vectorBackend;
    emb = s.embeddings;
    cmp = s.compression;
    dc = s.decay;
    rf = s.reflection;
    rl = s.rateLimit;
    lg = s.langGraph;
    boolStr = b:
      if b
      then "true"
      else "false";
  in
    {
      OM_TIER = s.tier;
      OM_USE_SUMMARY_ONLY = boolStr s.useSummaryOnly;
    }
    // optionalAttrs (!s.telemetry) {OM_TELEMETRY = "false";}
    // optionalAttrs (mode == "http") {OM_PORT = toString cfg.service.port;}
    // optionalAttrs (s.mode != null) {OM_MODE = s.mode;}
    // optionalAttrs (s.logAuth != null) {OM_LOG_AUTH = boolStr s.logAuth;}
    # ── IDE ─────────────────────────────────────────────────────
    // optionalAttrs (s.ideMode != null) {OM_IDE_MODE = boolStr s.ideMode;}
    // optionalAttrs (s.ideAllowedOrigins != null) {
      OM_IDE_ALLOWED_ORIGINS = builtins.concatStringsSep "," s.ideAllowedOrigins;
    }
    # ── Metadata backend ────────────────────────────────────────
    // optionalAttrs (meta ? sqlite) {
      OM_METADATA_BACKEND = "sqlite";
      OM_DB_PATH = meta.sqlite.path;
    }
    // optionalAttrs (meta ? postgres) (
      {
        OM_METADATA_BACKEND = "postgres";
        OM_PG_HOST = meta.postgres.host;
        OM_PG_PORT = toString meta.postgres.port;
        OM_PG_DB = meta.postgres.db;
      }
      // optionalAttrs (meta.postgres.user != null) {OM_PG_USER = meta.postgres.user;}
      // optionalAttrs (meta.postgres.password != null) {OM_PG_PASSWORD = meta.postgres.password;}
      // optionalAttrs (meta.postgres.ssl != null) {OM_PG_SSL = meta.postgres.ssl;}
      // optionalAttrs (meta.postgres.schema != "public") {OM_PG_SCHEMA = meta.postgres.schema;}
      // optionalAttrs (meta.postgres.table != "openmemory_memories") {OM_PG_TABLE = meta.postgres.table;}
    )
    # ── Vector backend ──────────────────────────────────────────
    // optionalAttrs (vec ? sqlite) (
      {OM_VECTOR_BACKEND = "sqlite";}
      // optionalAttrs (vec.sqlite.table != "vectors") {OM_VECTOR_TABLE = vec.sqlite.table;}
    )
    // optionalAttrs (vec ? postgres) (
      {OM_VECTOR_BACKEND = "postgres";}
      // optionalAttrs (vec.postgres.table != "openmemory_vectors") {OM_VECTOR_TABLE = vec.postgres.table;}
    )
    // optionalAttrs (vec ? valkey) (
      {
        OM_VECTOR_BACKEND = "valkey";
        OM_VALKEY_HOST = vec.valkey.host;
        OM_VALKEY_PORT = toString vec.valkey.port;
      }
      // optionalAttrs (vec.valkey.password != null) {OM_VALKEY_PASSWORD = vec.valkey.password;}
    )
    # ── Embeddings ──────────────────────────────────────────────
    // optionalAttrs (emb ? ollama) {
      OM_EMBEDDINGS = "ollama";
      OM_OLLAMA_URL = emb.ollama.url;
      OM_OLLAMA_MODEL = emb.ollama.model;
    }
    // optionalAttrs (emb ? openai) (
      {OM_EMBEDDINGS = "openai";}
      // optionalAttrs (emb.openai.baseUrl != null) {OM_OPENAI_BASE_URL = emb.openai.baseUrl;}
      // optionalAttrs (emb.openai.model != null) {OM_OPENAI_MODEL = emb.openai.model;}
    )
    // optionalAttrs (emb ? gemini) {OM_EMBEDDINGS = "gemini";}
    // optionalAttrs (emb ? aws) {OM_EMBEDDINGS = "aws";}
    // optionalAttrs (emb ? local) (
      {OM_EMBEDDINGS = "local";}
      // optionalAttrs (emb.local.modelPath != null) {OM_LOCAL_MODEL_PATH = emb.local.modelPath;}
    )
    // optionalAttrs (emb ? synthetic) {OM_EMBEDDINGS = "synthetic";}
    # ── Vector dimensions ───────────────────────────────────────
    // optionalAttrs (s.vecDim != null) {OM_VEC_DIM = toString s.vecDim;}
    // optionalAttrs (s.maxVectorDim != null) {OM_MAX_VECTOR_DIM = toString s.maxVectorDim;}
    // optionalAttrs (s.minVectorDim != null) {OM_MIN_VECTOR_DIM = toString s.minVectorDim;}
    # ── Embedding tuning ────────────────────────────────────────
    // optionalAttrs (s.embedMode != null) {OM_EMBED_MODE = s.embedMode;}
    // optionalAttrs (s.embedTimeoutMs != null) {OM_EMBED_TIMEOUT_MS = toString s.embedTimeoutMs;}
    // optionalAttrs (s.embedDelayMs != null) {OM_EMBED_DELAY_MS = toString s.embedDelayMs;}
    // optionalAttrs (s.embedFallback != null) {OM_EMBEDDING_FALLBACK = s.embedFallback;}
    // optionalAttrs (s.advEmbedParallel != null) {OM_ADV_EMBED_PARALLEL = boolStr s.advEmbedParallel;}
    // optionalAttrs (s.cacheSegments != null) {OM_CACHE_SEGMENTS = toString s.cacheSegments;}
    # ── Summary ─────────────────────────────────────────────────
    // optionalAttrs (s.summaryLayers != null) {OM_SUMMARY_LAYERS = toString s.summaryLayers;}
    // optionalAttrs (s.summaryMaxLength != null) {OM_SUMMARY_MAX_LENGTH = toString s.summaryMaxLength;}
    # ── Search & relevance ──────────────────────────────────────
    // optionalAttrs (s.minScore != null) {OM_MIN_SCORE = s.minScore;}
    // optionalAttrs (s.keywordBoost != null) {OM_KEYWORD_BOOST = s.keywordBoost;}
    // optionalAttrs (s.keywordMinLength != null) {OM_KEYWORD_MIN_LENGTH = toString s.keywordMinLength;}
    # ── Segmentation & compression ──────────────────────────────
    // optionalAttrs (s.segSize != null) {OM_SEG_SIZE = toString s.segSize;}
    // optionalAttrs (cmp.enabled != null) {OM_COMPRESSION_ENABLED = boolStr cmp.enabled;}
    // optionalAttrs (cmp.algorithm != null) {OM_COMPRESSION_ALGORITHM = cmp.algorithm;}
    // optionalAttrs (cmp.minLength != null) {OM_COMPRESSION_MIN_LENGTH = toString cmp.minLength;}
    # ── Decay ───────────────────────────────────────────────────
    // optionalAttrs (dc.intervalMinutes != null) {OM_DECAY_INTERVAL_MINUTES = toString dc.intervalMinutes;}
    // optionalAttrs (dc.lambda != null) {OM_DECAY_LAMBDA = dc.lambda;}
    // optionalAttrs (dc.ratio != null) {OM_DECAY_RATIO = dc.ratio;}
    // optionalAttrs (dc.threads != null) {OM_DECAY_THREADS = toString dc.threads;}
    // optionalAttrs (dc.coldThreshold != null) {OM_DECAY_COLD_THRESHOLD = dc.coldThreshold;}
    // optionalAttrs (dc.reinforceOnQuery != null) {OM_DECAY_REINFORCE_ON_QUERY = boolStr dc.reinforceOnQuery;}
    // optionalAttrs (dc.sleepMs != null) {OM_DECAY_SLEEP_MS = toString dc.sleepMs;}
    # ── Reflection & regeneration ───────────────────────────────
    // optionalAttrs (rf.autoReflect != null) {OM_AUTO_REFLECT = boolStr rf.autoReflect;}
    // optionalAttrs (rf.interval != null) {OM_REFLECT_INTERVAL = toString rf.interval;}
    // optionalAttrs (rf.minMemories != null) {OM_REFLECT_MIN_MEMORIES = toString rf.minMemories;}
    // optionalAttrs (rf.regenerationEnabled != null) {OM_REGENERATION_ENABLED = boolStr rf.regenerationEnabled;}
    // optionalAttrs (rf.userSummaryInterval != null) {OM_USER_SUMMARY_INTERVAL = toString rf.userSummaryInterval;}
    # ── Rate limiting ───────────────────────────────────────────
    // optionalAttrs (rl.enabled != null) {OM_RATE_LIMIT_ENABLED = boolStr rl.enabled;}
    // optionalAttrs (rl.maxRequests != null) {OM_RATE_LIMIT_MAX_REQUESTS = toString rl.maxRequests;}
    // optionalAttrs (rl.windowMs != null) {OM_RATE_LIMIT_WINDOW_MS = toString rl.windowMs;}
    # ── Performance & limits ────────────────────────────────────
    // optionalAttrs (s.maxActive != null) {OM_MAX_ACTIVE = toString s.maxActive;}
    // optionalAttrs (s.maxPayloadSize != null) {OM_MAX_PAYLOAD_SIZE = toString s.maxPayloadSize;}
    # ── LangGraph ───────────────────────────────────────────────
    // optionalAttrs (lg.namespace != null) {OM_LG_NAMESPACE = lg.namespace;}
    // optionalAttrs (lg.maxContext != null) {OM_LG_MAX_CONTEXT = toString lg.maxContext;}
    // optionalAttrs (lg.reflective != null) {OM_LG_REFLECTIVE = boolStr lg.reflective;};

  settingsToArgs = _cfg: _mode: [];
}
