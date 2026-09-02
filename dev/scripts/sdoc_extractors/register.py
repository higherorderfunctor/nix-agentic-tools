# cspell:ignore dlopens reqs sdoc
"""Registering an extractor as a strictdoc source reader, with zero package edits.

`SourceCodeReaderRegistry.get_reader` is resolved AT CALL TIME by both of its
call sites (`caching_reader.py` and the Markdown reader), so reassigning it
from `strictdoc_config.py` is enough. strictdoc imports that module before it
builds the traceability index, which is why the call belongs at MODULE level
there rather than inside `create_config()`.

`staticmethod(...)` around the replacement is load-bearing: `get_reader` is
declared as one, and a bare function assigned onto the class would bind `self`
to the first positional argument.

Two properties this helper adds over the four-line inline version:

* FAIL-CLOSED. The overlay tracks latest upstream, so a renamed or restructured
  registry must exit naming THIS file rather than silently leaving the reader
  unregistered -- a silent miss is indistinguishable from a corpus with no
  matching source files.

* IDEMPOTENT. Re-importing the config (a second `create_config()`, a test
  harness, a daemon reload) must not wrap the wrapper: each layer would keep a
  reference to the one below and the chain would grow without bound.

The factory is LAZY. Building an extractor dlopens a grammar and compiles every
query; doing that at registration would make a missing grammar break every
strictdoc invocation, including the ones that read no source files at all --
which, with REQUIREMENT_TO_SOURCE_TRACEABILITY off, is all of them.
"""

from __future__ import annotations

from typing import Callable, Mapping

#: Marks a patched `get_reader` so a second registration is a no-op.
_PATCH_FLAG = "_sdoc_extractors_patched"


class RegistrationError(Exception):
    """strictdoc's reader registry is not the shape this patch expects."""


def register_readers(
    factories: Mapping[str, Callable[..., object]],
) -> bool:
    """Route source files by extension to `factories`, else to strictdoc.

    `factories` maps a file suffix (".nix") to a zero-or-one-argument callable
    taking the source node tags and returning a reader. Returns True when this
    call installed the patch, False when it was already installed.
    """
    try:
        from strictdoc.backend.sdoc_source_code import reader_registry
    except ImportError as error:  # pragma: no cover - environment failure
        raise RegistrationError(
            "dev/scripts/sdoc_extractors/register.py: strictdoc no longer "
            "exposes strictdoc.backend.sdoc_source_code.reader_registry"
        ) from error

    registry = getattr(reader_registry, "SourceCodeReaderRegistry", None)
    if registry is None:
        raise RegistrationError(
            "dev/scripts/sdoc_extractors/register.py: "
            "reader_registry.SourceCodeReaderRegistry is gone"
        )
    if not isinstance(registry.__dict__.get("get_reader"), staticmethod):
        raise RegistrationError(
            "dev/scripts/sdoc_extractors/register.py: "
            "SourceCodeReaderRegistry.get_reader is no longer a staticmethod; "
            "re-check the patch shape before assuming it still works"
        )

    original = registry.get_reader
    if getattr(original, _PATCH_FLAG, False):
        return False

    routes = dict(factories)

    def get_reader(path_to_file, project_config, source_node_tags=None):
        for suffix, factory in routes.items():
            if path_to_file.endswith(suffix):
                return factory(source_node_tags)
        return original(path_to_file, project_config, source_node_tags)

    setattr(get_reader, _PATCH_FLAG, True)
    registry.get_reader = staticmethod(get_reader)
    return True


def register_forward_descriptions() -> bool:
    """Make a FORWARD File relation render the item's KIND, not `function x()`.

    THIS IS THE "new relation type renders properly" TWEAK, and without it half
    the work is invisible. A BACKWARD marker -- an `@relation(...)` in a source
    comment -- carries whatever description the reader set, so `option
    services.foo.enable` shows. A FORWARD marker -- `TYPE: File` with
    `ELEMENT`/`ID` in a `.sdoc` -- is built by strictdoc from the LanguageItem
    AFTER the reader is finished, and
    `FileTraceabilityIndex.forward_marker_from_language_item` hardcodes
    `function <name>()` or `class <name>`. Measured: a File relation to a Nix
    option rendered `function options.services.foo.port()`, parentheses and
    all.

    The function already takes a `description` argument; every caller passes
    None. So this wrapper fills it in from the `sdoc_kind` attribute the reader
    stashes on each LanguageItem (see strictdoc_reader.py), and leaves items
    from strictdoc's own readers -- which have no such attribute -- alone.

    Same three properties as `register_readers`: resolved at call time, so no
    package edit; fail-closed on a shape change; idempotent.
    """
    try:
        from strictdoc.core.file_traceability_index import FileTraceabilityIndex
    except ImportError as error:  # pragma: no cover - environment failure
        raise RegistrationError(
            "dev/scripts/sdoc_extractors/register.py: strictdoc no longer "
            "exposes strictdoc.core.file_traceability_index"
        ) from error

    name = "forward_marker_from_language_item"
    if not isinstance(
        FileTraceabilityIndex.__dict__.get(name), staticmethod
    ):
        raise RegistrationError(
            f"dev/scripts/sdoc_extractors/register.py: FileTraceabilityIndex.{name} "
            "is no longer a staticmethod; forward File relations would render "
            "strictdoc's generic label instead of the item kind"
        )

    original = getattr(FileTraceabilityIndex, name)
    if getattr(original, _PATCH_FLAG, False):
        return False

    def forward_marker_from_language_item(
        function, marker_type, reqs, role, description=None
    ):
        if description is None:
            kind = getattr(function, "sdoc_kind", None)
            if kind:
                description = f"{kind} {function.display_name}"
        return original(function, marker_type, reqs, role, description)

    setattr(forward_marker_from_language_item, _PATCH_FLAG, True)
    setattr(
        FileTraceabilityIndex,
        name,
        staticmethod(forward_marker_from_language_item),
    )
    return True
