# Shared NixOS module type for buddy companion options.
#
# Used by both modules/claude-code-buddy/default.nix (canonical, extends
# upstream programs.claude-code) and modules/ai/default.nix (convenience
# fanout via ai.claude.buddy).
{lib}: let
  inherit (lib) mkOption types;

  speciesEnum = types.enum [
    "axolotl"
    "blob"
    "cactus"
    "capybara"
    "cat"
    "chonk"
    "dragon"
    "duck"
    "ghost"
    "goose"
    "mushroom"
    "octopus"
    "owl"
    "penguin"
    "rabbit"
    "robot"
    "snail"
    "turtle"
  ];

  rarityEnum = types.enum [
    "common"
    "epic"
    "legendary"
    "rare"
    "uncommon"
  ];

  eyesEnum = types.enum [
    "·"
    "✦"
    "×"
    "◉"
    "@"
    "°"
  ];

  hatEnum = types.enum [
    "beanie"
    "crown"
    "halo"
    "none"
    "propeller"
    "tinyduck"
    "tophat"
    "wizard"
  ];

  statEnum = types.enum [
    "CHAOS"
    "DEBUGGING"
    "PATIENCE"
    "SNARK"
    "WISDOM"
  ];
in {
  buddySubmodule = types.submodule {
    options = {
      userId = mkOption {
        type = types.attrTag {
          text = mkOption {
            type = types.str;
            description = ''
              Literal Claude account UUID string. Get it from
              ~/.claude.json under oauthAccount.accountUuid.
            '';
            example = "ebd8b240-9b28-44b1-a4bf-da487d9f111f";
          };
          file = mkOption {
            type = types.path;
            description = ''
              Path to a file containing the Claude account UUID.
              Read at activation time, so sops-nix and agenix paths
              work. Trailing whitespace is stripped.
            '';
            example = lib.literalExpression ''
              config.sops.secrets."''${username}-claude-uuid".path
            '';
          };
        };
        description = ''
          Claude account UUID source. Provide exactly one of `text`
          (literal string) or `file` (path to file read at activation).
        '';
      };

      species = mkOption {
        type = speciesEnum;
        description = "Buddy species (one of 18).";
        example = "duck";
      };

      rarity = mkOption {
        type = rarityEnum;
        default = "common";
        description = ''
          Rarity tier. Higher rarities take longer to compute at
          activation time:
          - common: instant (~180 attempts)
          - uncommon/rare: <1s
          - epic: ~1s
          - legendary: ~1s (or ~30s shiny, minutes shiny+stats)

          The salt search is cached by a fingerprint of buddy options
          + claude-code version + userId — only re-runs when something
          changes.
        '';
      };

      eyes = mkOption {
        type = eyesEnum;
        default = "·";
        description = "Eye character.";
      };

      hat = mkOption {
        type = hatEnum;
        default = "none";
        description = ''
          Hat accessory. Must be "none" for common rarity (assertion
          enforced at module evaluation).
        '';
      };

      shiny = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Rainbow shimmer variant. Significantly increases salt search
          time (~100x more attempts).
        '';
      };

      peak = mkOption {
        type = types.nullOr statEnum;
        default = null;
        description = ''
          Preferred highest stat. null = accept whatever the salt
          produces. Increases search time ~5x.
        '';
      };

      dump = mkOption {
        type = types.nullOr statEnum;
        default = null;
        description = ''
          Preferred lowest stat. Must differ from peak when both are
          set. null = accept whatever the salt produces.
        '';
      };
    };
  };
}
