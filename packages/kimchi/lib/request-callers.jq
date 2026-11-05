[.["#select"].tuples[] |
 . as [$file, $line, $column, $library, $functionFile, $functionLine, $functionColumn,
        $kind, $siteFile, $siteLine, $siteColumn, $property, $reason, $distance] |
 {callSite: {file: $file, line: $line, column: $column, library: $library},
  functionSite: {file: $functionFile, line: $functionLine, column: $functionColumn},
  kind: $kind, site: {file: $siteFile, line: $siteLine, column: $siteColumn},
  property: (if $property == "" then null else $property end),
  reason: (if $reason == "" then null else $reason end), distance: $distance}]
| unique | sort_by([.callSite.file, .callSite.line, .callSite.column, .callSite.library,
                   .distance, .functionSite.file, .functionSite.line, .functionSite.column,
                   .kind, .site.file, .site.line, .site.column, .property, .reason])
