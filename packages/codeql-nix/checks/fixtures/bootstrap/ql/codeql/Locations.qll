/** Minimal language interface required by kit-generated syntax. */
overlay[local]
module;
class File extends @file {
  string getAbsolutePath() { files(this, result) }
  string getRelativePath() {
    exists(string prefix | sourceLocationPrefix(prefix) |
      this.getAbsolutePath() = prefix.regexpReplaceAll("/$", "") + "/" + result and
      not result.matches("/%")
    )
  }
  string toString() { result = this.getAbsolutePath() }
}

class Location extends @location_default {
  File getFile() { locations_default(this, result, _, _, _, _) }
  int getStartLine() { locations_default(this, _, result, _, _, _) }
  int getStartColumn() { locations_default(this, _, _, result, _, _) }
  int getEndLine() { locations_default(this, _, _, _, result, _) }
  int getEndColumn() { locations_default(this, _, _, _, _, result) }
  string toString() { result = this.getFile().toString() }
}
