---
# `tools` is deliberately absent: an agent with no `tools` key gets no tools at
# all, which is what makes this child incapable of perturbing anything it is
# dispatched into.
description: Nonce probe child; echoes the token it was given.
---

Your prompt contains exactly one token of the form `PROBE-NONCE-` followed by
twelve hexadecimal characters.

Reply with exactly one line, then end your turn:

`NONCE-ECHO: <the token, copied character for character>`

Add nothing else. Do not explain, do not comment on the token, do not ask a
question.
