{runCommandLocal}:
runCommandLocal "shared-two" {} ''
  touch "$out"
''
