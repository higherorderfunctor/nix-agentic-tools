import EvalTables
from string path, string present, string absent
where
  present in ["devenv", "home-manager"] and
  absent in ["devenv", "home-manager"] and present != absent and
  path.matches("ai.%") and
  evalOption(present, path, _, _, _, _, _, _, _, _, _, _, "") and
  not evalOption(absent, path, _, _, _, _, _, _, _, _, _, _, "")
select present, absent, path
