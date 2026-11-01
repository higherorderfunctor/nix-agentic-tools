# cspell:ignore codeberg
# Official ed25519 pins consumed by settings.forges; no first-use trust.
{
  # https://codeberg.org/Codeberg/org/src/branch/main/Imprint.md#ssh-host-keys
  "codeberg.org".hostKeys = ''
    codeberg.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVIC02vnjFyL+I4RHfvIGNtOgJMe769VTF1VR4EB3ZB
  '';
  # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
  "github.com".hostKeys = ''
    github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
  '';
  # https://docs.gitlab.com/user/gitlab_com/#ssh-known_hosts-entries
  # Source: https://gitlab.com/gitlab-org/gitlab/-/raw/master/doc/user/gitlab_com/_index.md
  "gitlab.com".hostKeys = ''
    gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf
  '';
}
