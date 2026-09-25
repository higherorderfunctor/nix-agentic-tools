# Appended to a Semble interpreter header, so numpy, safetensors and tokenizers
# come from Semble's own closure. Writes a tiny model2vec model (the default
# layout: config.json, model.safetensors, tokenizer.json) to argv[1].
import json
import sys
from pathlib import Path

import numpy as np
from safetensors.numpy import save_file
from tokenizers import Tokenizer, models, pre_tokenizers

out = Path(sys.argv[1])
out.mkdir(parents=True)
words = ["[UNK]", "[PAD]", "alpha", "beta", "gamma", "def", "return", "guide", "install", "config"]
tokenizer = Tokenizer(models.WordLevel(vocab={word: index for index, word in enumerate(words)}, unk_token="[UNK]"))
tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
tokenizer.save(str(out / "tokenizer.json"))
vectors = np.random.default_rng(int(sys.argv[2])).standard_normal((len(words), 8)).astype(np.float32)
save_file({"embeddings": vectors}, str(out / "model.safetensors"))
(out / "config.json").write_text(json.dumps({"hidden_dim": 8, "model_type": "model2vec", "normalize": True}))
