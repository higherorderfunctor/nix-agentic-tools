# cspell:words newurl
"""Read today's Workers AI neurons through CPA; credentials are never printed, persisted, or passed in argv."""

import datetime as dt
from http.client import HTTPException
import json
import math
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

QUERY = "query WorkersAINeurons($account:String!,$date:Date!){viewer{accounts(filter:{accountTag:$account}){accountTag aiInferenceAdaptiveGroups(limit:1,filter:{date_geq:$date,date_leq:$date}){sum{totalNeurons} count}}}}"
SURFACES = ("claude", "codex", "openai-compatibility", "passthrough")


class Invalid(ValueError):
    """A static diagnostic safe to print even when inputs contain credentials."""


def require(condition, message):
    if not condition:
        raise Invalid(message)


def single_line(value):
    return isinstance(value, str) and bool(value) and all(
        32 < ord(char) < 127 for char in value
    )


def read_secret(path):
    try:
        value = Path(path).read_text().rstrip("\n")
    except (OSError, ValueError):
        raise Invalid("cannot read required secret file") from None
    require(single_line(value), "secret file must contain one nonempty line")
    return value


class NoRedirect(HTTPRedirectHandler):
    # Redirects could forward the management Authorization header to another host.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Management:
    def __init__(self, url, key):
        try:
            parsed = urlsplit(url)
            valid = (
                single_line(url)
                and parsed.scheme in ("http", "https")
                and parsed.hostname
                and parsed.port != 0
                and parsed.username is None
                and parsed.password is None
                and not parsed.query
                and not parsed.fragment
                and "\\" not in url
            )
        except ValueError:
            valid = False
        require(valid, "invalid management URL")
        self.url = url.rstrip("/")
        self.key = key
        # Ignore ambient proxy variables: the configured CPA URL is the transport.
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def request(self, method, path, payload=None, optional=False):
        request = Request(
            self.url + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={
                "Authorization": "Bearer " + self.key,
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with self.opener.open(request, timeout=75) as response:
                require(200 <= response.status < 300, "management HTTP failure")
                return json.load(response)
        except HTTPError as error:
            status = error.code
            error.close()
            if optional and status == 404:
                return []
            raise Invalid("management HTTP failure") from None
        except (HTTPException, OSError, URLError, ValueError):
            raise Invalid("invalid management response or transport failure") from None

    def discover(self):
        candidates = {}
        for surface in SURFACES:
            groups = self.request(
                "GET",
                "/v8/management/config/api-keys/" + surface,
                optional=surface == "passthrough",
            )
            require(isinstance(groups, list), "invalid config projection")
            for group in groups:
                require(isinstance(group, dict), "invalid config group")
                # The endpoint supplies family identity; grouped families also
                # require their actual provider name, as CPA's synthesizer does.
                if surface in ("openai-compatibility", "passthrough"):
                    name = group.get("name")
                    require(isinstance(name, str) and bool(name.strip()), "invalid provider identity")
                base = group.get("base-url", "")
                require(isinstance(base, str), "invalid config base URL")
                try:
                    parsed = urlsplit(base)
                    path = parsed.path.rstrip("/")
                    matches = (
                        parsed.scheme == "https"
                        and parsed.hostname == "api.cloudflare.com"
                        and parsed.port in (None, 443)
                        and parsed.username is None
                        and parsed.password is None
                        and not parsed.query
                        and not parsed.fragment
                        and single_line(base)
                        and (not path or path == "/client/v4" or path.startswith("/client/v4/"))
                    )
                except ValueError:
                    raise Invalid("invalid config base URL") from None
                if not matches:
                    continue
                keys = group.get("keys")
                require(isinstance(keys, list), "invalid config keys")
                for key in keys:
                    require(isinstance(key, dict), "invalid config key")
                    credential = key.get("api-key")
                    index = key.get("auth_index")
                    require(single_line(credential), "missing API key")
                    require(single_line(index), "missing auth index")
                    candidates.setdefault(credential, index)
        require(len(candidates) == 1, "requires exactly one distinct Cloudflare credential")
        return next(iter(candidates.values()))


def project(body, account, limit, index, now):
    require(isinstance(body, dict) and not body.get("errors"), "GraphQL query failed")
    try:
        accounts = body["data"]["viewer"]["accounts"]
        require(isinstance(accounts, list) and len(accounts) == 1, "requires one account")
        require(accounts[0]["accountTag"] == account, "account mismatch")
        groups = accounts[0]["aiInferenceAdaptiveGroups"]
        require(isinstance(groups, list) and len(groups) <= 1, "invalid neurons groups")
        neurons = groups[0]["sum"]["totalNeurons"] if groups else 0
        require(
            type(neurons) in (int, float) and math.isfinite(neurons) and neurons >= 0,
            "invalid neurons value",
        )
        used = neurons / limit * 100
        require(math.isfinite(used), "invalid usage percentage")
    except (KeyError, TypeError, OverflowError):
        raise Invalid("invalid analytics response") from None
    reset = dt.datetime.combine(now.date() + dt.timedelta(days=1), dt.time(), dt.UTC)
    return {
        "account": {"auth_index": index, "name": index, "plan": None},
        "balances": [],
        "bonuses": [],
        "pool": "cloudflare",
        "windows": {
            "daily": {
                "remainingPercent": max(0, 100 - used),
                "resetsAt": reset.isoformat().replace("+00:00", "Z"),
                "status": None,
                "usedPercent": used,
                "windowSeconds": 86400,
            }
        },
    }


def main(argv=None, environ=None, clock=None):
    argv = sys.argv[1:] if argv is None else argv
    environ = os.environ if environ is None else environ
    try:
        require(len(argv) == 1 and argv[0] in ("claude", "codex"), "expected claude or codex")
        prefix = "DELEGATE_USAGE_CPA_" + argv[0].upper()
        url = environ.get(prefix + "_URL", "")
        key_file = environ.get(prefix + "_MANAGEMENT_KEY_FILE", "")
        require(bool(url and key_file), "requires matching runtime URL and management-key file")
        account_file = environ.get("CLOUDFLARE_ACCOUNT_ID_FILE", "")
        require(bool(account_file), "requires account-ID file")
        account = read_secret(account_file)
        require(re.fullmatch(r"[a-fA-F0-9]{32}", account), "invalid account ID")
        limit = float(environ.get("CLOUDFLARE_DAILY_NEURONS_LIMIT", ""))
        require(math.isfinite(limit) and limit > 0, "requires positive finite daily neurons limit")
        management = Management(url, read_secret(key_file))
        index = environ.get("CLOUDFLARE_AUTH_INDEX")
        if index is None:
            index = management.discover()
        else:
            require(single_line(index), "invalid auth-index override")
        now = (clock() if clock else dt.datetime.now(dt.UTC)).astimezone(dt.UTC)
        envelope = management.request(
            "POST",
            "/v0/management/api-call",
            {
                "auth_index": index,
                "data": json.dumps({"query": QUERY, "variables": {"account": account, "date": now.date().isoformat()}}),
                "header": {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"},
                "method": "POST",
                "url": "https://api.cloudflare.com/client/v4/graphql",
            },
        )
        require(isinstance(envelope, dict), "invalid api-call envelope")
        status = envelope.get("status_code")
        require(type(status) is int and 200 <= status < 300, "upstream HTTP failure")
        require(isinstance(envelope.get("body"), str), "invalid api-call body")
        result = project(json.loads(envelope["body"]), account, limit, index, now)
        print(json.dumps(result, allow_nan=False))
        return 0
    except Invalid as error:
        print("cloudflare-usage: " + str(error), file=sys.stderr)
    except (ValueError, TypeError, OSError, OverflowError):
        print("cloudflare-usage: invalid input or response", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
