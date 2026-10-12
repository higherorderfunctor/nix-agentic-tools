# Shared by package selection and the CI canary. Omitted and null restrictions
# have the same unrestricted meaning as the manifest's all/stable values.
{
  needsPatch = state: let
    unrestricted = key: fallback: let
      value = state.${key} or null;
    in
      value == null || value == fallback;
  in
    !(state.treatment_percent == 100 && unrestricted "segment" "all" && unrestricted "channel" "stable");
}
