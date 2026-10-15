# Shared by package selection and the CI canary. Omitted and null restrictions
# have the same unrestricted meaning as the manifest's all/stable values.
{
  needsPatch = {
    channel ? null,
    internal_treatment_percent ? treatment_percent,
    segment ? null,
    treatment_percent,
  }:
    !(treatment_percent == 100 && internal_treatment_percent == 100 && (segment == null || segment == "all") && (channel == null || channel == "stable"));
}
