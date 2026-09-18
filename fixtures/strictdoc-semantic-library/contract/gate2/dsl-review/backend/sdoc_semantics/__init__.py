"""The semantic constraint evaluator for the reference model packet.

``evaluate`` is the one public entry point, re-exported from the engine so a
caller and the test harness import a single name. The re-export is resolved on
first attribute access rather than at import time, so importing one submodule
never drags the whole engine in.
"""

__all__ = ["evaluate"]


def __getattr__(name):
    if name == "evaluate":
        from .engine import evaluate_bundle

        return evaluate_bundle
    raise AttributeError("module " + __name__ + " has no attribute " + name)


def __dir__():
    return sorted(__all__)
