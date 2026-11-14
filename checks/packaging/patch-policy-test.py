"""The packaging check exercises forbidden commands and allowed read-only forms."""

import pathlib
import runpy
import sys

from hypothesis import given, settings, strategies as st

policy = runpy.run_path(sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).with_name('patch-policy.py')))
violations = policy['violations']
# cspell:words derandomize
settings.register_profile('policy', database=None, derandomize=True, max_examples=250)
settings.load_profile('policy')
CONTEXTS = st.sampled_from([
    '{}', 'if {}; then echo ok; fi',
    'if false; then echo skip; elif {}; then echo ok; fi',
    'if true; then {}; else echo skip; fi',
    'if false; then echo skip; else {}; fi',
    'until {}; do echo retry; done', 'while {}; do echo retry; done',
    'for input in fix.patch; do {}; done', '! {}', '{{ {}; }}',
])
GIT = st.sampled_from(['git', '/usr/bin/git', '${pkgs.git}/bin/git', '${lib.getExe pkgs.gitMinimal}'])


def shell_violations(command):
    return violations('packages/example/package.nix', f"postPatch = ''{command}'';")


@given(
    executable=st.sampled_from(['patch', '/usr/bin/patch', '"/usr/bin/patch"', '${pkgs.gnupatch}/bin/patch', '${lib.getExe pkgs.patch}']),
    separator=st.sampled_from([' ', '\t', '\\\n ']),
    context=CONTEXTS,
)
def test_patch_application_is_refused_in_compound_commands(executable, separator, context):
    """Operators, indentation and continuations cannot hide GNU patch."""
    assert shell_violations(context.format(executable + separator + '-p1 <fix.patch'))


@given(executable=GIT, context=CONTEXTS, read_only=st.booleans(),
       directory=st.sampled_from(['', '-C "path with spaces" ', '-C ${source} ']),
       placement=st.sampled_from(['before', 'after', 'comment', 'quoted', 'terminator', 'explicit']))
def test_git_check_depends_on_options_not_filenames(executable, context, read_only, directory, placement):
    """Redirect operands and comments cannot grant or remove read-only status."""
    options = '--check ' if read_only else ''
    command = executable + ' ' + directory + 'apply ' + options
    if placement == 'before':
        command = executable + '<fix.patch ' + directory + 'apply ' + options
    elif placement == 'after':
        command += '<"--apply"' if read_only else '<"--check"'
    elif placement == 'comment':
        command += 'fix.patch # --apply --check\n'
    elif placement == 'quoted':
        command += '"operand --check --apply name.patch"'
    elif placement == 'terminator':
        command += '-- --apply --check'
    else:
        command += '--apply fix.patch'
    assert bool(shell_violations(context.format(command))) == (not read_only or placement == 'explicit')


@given(name=st.sampled_from(['patches', 'patchFlags']), quoted=st.booleans(),
       spacing=st.sampled_from([' ', '\n', '\t']), inherited=st.booleans())
def test_direct_patch_attributes_cannot_bypass_helper(name, quoted, spacing, inherited):
    """Quoted bindings and inherited attributes still route through the helper."""
    attribute = f'"{name}"' if quoted else name
    source = f'inherit (old){spacing}{attribute};' if inherited else f'{attribute}{spacing}= [];'
    assert violations('packages/example/package.nix', source)


@given(command=st.sampled_from(['patch -p1', 'git apply', 'if patch; then git apply; fi']))
def test_comments_and_echo_operands_are_not_applications(command):
    """Text mentioning commands is harmless unless it occupies command position."""
    assert not shell_violations(f"# {command}\necho '{command}'")
    assert not violations('packages/example/package.nix', '# patches = [];\n/* pkgs.applyPatches {}; */')


def test_nix_interpolations_and_helper_calls_keep_their_meaning():
    """Nested Nix applications are refused while unknown values stay operands."""
    for source in ['pkgs."applyPatches" {src = upstream;}', '"${pkgs.applyPatches {src = upstream;}}"']:
        assert violations('packages/example/package.nix', source)
    for source in [
        'description = "patch the binary";',
        'src = (packageLib.patching {inherit pkgs;}).source {patchFiles = [./fix.patch];};',
        "postPatch = ''${pkgs.git}/bin/git -C ${source} apply --check fix.patch'';",
        "postPatch = ''echo ''${value}; git diff -- apply.patch'';",
    ]:
        assert not violations('packages/example/package.nix', source), source


def test_negative_controls_allow_only_the_exact_fixture_operation():
    """Changing a fixture or appending a bypass must still fail the policy."""
    for path, snippets in policy['FIXTURES'].items():
        source = '\n'.join(snippets)
        assert not violations(path, source)
        assert violations(path, source + '\npatchFlags = [];')
        assert violations(path, source.replace(snippets[0], ''))


for test in [
    test_comments_and_echo_operands_are_not_applications,
    test_direct_patch_attributes_cannot_bypass_helper,
    test_git_check_depends_on_options_not_filenames,
    test_negative_controls_allow_only_the_exact_fixture_operation,
    test_nix_interpolations_and_helper_calls_keep_their_meaning,
    test_patch_application_is_refused_in_compound_commands,
]:
    test()
    print('PASS:', test.__name__)
