import Hooks
class FixtureModel extends HookContract::FixtureBuiltinFrame {
  FixtureModel() { this = "outermost-builtin-frame" }
  override string getModelIdentity() { result = "other-runtime" }
}
from string file, int line, int column, string name, string status,
  int mayCount, int mustCount, string targets
where HookContract::row(file, line, column, name, status, mayCount, mustCount, targets)
select file, line, column, name, status, mayCount, mustCount, targets
