{runCommandLocal}:
runCommandLocal "shared-one" {} ''
  touch "$out"
''
