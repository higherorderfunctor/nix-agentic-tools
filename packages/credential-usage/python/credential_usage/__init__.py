"""The shared usage-reading contract, imported by Reader programs and their consumers.

`envelope` is the typed output a Reader prints; the Claude Reader is its first
producer, and delegate-routing still parses Reader stdout itself until it
switches to these models. `runner` runs registered Reader commands and returns
their raw captures or safe failures. `transport` defines the request a Reader
sends, the credential-bound transport it sends through, and the direct HTTP
binding; delegate-routing imports `runner` and `transport` today. CPA and
Airlock each supply their own transport. `docs/credential-usage.md` records the
ownership.
"""
