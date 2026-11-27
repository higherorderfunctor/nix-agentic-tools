"""Load Semble's real default model offline under the pinned model2vec.

argv[1] is the directory holding the model's three files. A load that cannot
read the int8 weights fails here; a dequantized result of the wrong shape or
dtype, or one that is not unit length (the model's `normalize: true`), fails
the assertions.
"""

import sys

import numpy as np
from model2vec import StaticModel

model = StaticModel.from_pretrained(sys.argv[1])
vectors = model.encode(["def alpha():\n    return beta", "install guide"])
assert vectors.shape == (2, 256), vectors.shape
assert vectors.dtype == np.float32, vectors.dtype
assert np.allclose(np.linalg.norm(vectors, axis=1), 1.0, atol=1e-3), vectors
assert not np.allclose(vectors[0], vectors[1])
