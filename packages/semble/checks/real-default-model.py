"""Check Semble loads and encodes with its real default from the offline Hub cache."""

import numpy as np
from semble.index.dense import load_model

model, model_id = load_model()
assert model_id == "minishlab/blink-code-16M-int8", model_id

vectors = model.encode(["def alpha():\n    return beta", "install guide"])
assert vectors.shape == (2, 256), vectors.shape
assert vectors.dtype == np.float32, vectors.dtype
assert np.allclose(np.linalg.norm(vectors, axis=1), 1.0, atol=1e-3), vectors
assert not np.allclose(vectors[0], vectors[1]), "different inputs produced the same vector"
