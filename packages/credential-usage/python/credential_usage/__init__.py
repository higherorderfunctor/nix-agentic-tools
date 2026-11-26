"""The shared usage-reading contract, imported by Reader programs and their consumers.

`runner` runs registered Reader commands and returns their raw captures or safe
failures. `transport` defines the request a Reader sends, the credential-bound
transport it sends through, and the direct HTTP binding. delegate-routing imports
both today. Airlock's UI reads the same Reader output later, and CPA and Airlock
each supply their own transport. `docs/credential-usage.md` records the ownership.
"""
