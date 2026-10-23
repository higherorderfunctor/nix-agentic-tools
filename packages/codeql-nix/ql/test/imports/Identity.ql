import nix.Imports

from Imports::StaticImportSite site, @nx_file source, string sourceRoot, string sourceHash,
  int line, string status, string targetRoot, string targetPath, string targetHash, string reason
where
  source = site.getSourceFile() and nx_files(source, sourceRoot, "main.nix", sourceHash, _) and
  line = site.getLocation().getStartLine() and status = site.getStatus(source) and
  reason = site.getReason(source) and
  (nx_files(site.getTargetFile(source), targetRoot, targetPath, targetHash, _)
   or not exists(site.getTargetFile(source)) and
     targetRoot = "" and targetPath = "" and targetHash = "")
select sourceRoot, sourceHash, line, status, targetRoot, targetPath, targetHash, reason
