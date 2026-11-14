"""Explicit-manifest entry point; backend wrappers own account discovery."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from daemon import run
from login import login
from state import Account
from oauth import OAuthError


def manifest(path):
    return json.loads(Path(path).read_text())


GUM = "@gum@"


def choose(config, name, *, gum=GUM, display_names=None):
    accounts = config["accounts"]
    if not accounts:
        raise OAuthError("no accounts; configure an OAuth account in this backend")
    if name is not None:
        if name not in accounts:
            raise OAuthError("unknown account")
        return name
    if len(accounts) == 1:
        return next(iter(accounts))
    if not sys.stdin.isatty():
        raise OAuthError("multiple accounts; supply an explicit account name")
    # Reading labels must not reconcile/create state before a possible cancel.
    labels = {}
    for key, value in sorted(accounts.items()):
        status = Account(config["backend"], key, value).picker_status()
        label = (display_names or {}).get(key, key)
        labels[f"{label} — {status}"] = key
    options = [f"{label}\t{key}" for label, key in labels.items()]
    result = subprocess.run([gum, "choose", "--limit=1", "--label-delimiter=\t", "--", *options],
                            stdout=subprocess.PIPE, text=True)
    if result.returncode:
        raise OAuthError("account selection cancelled")
    selected = result.stdout.rstrip("\n")
    if selected not in labels.values():
        raise OAuthError("invalid account selection")
    return selected


def owner_selection(config, owner, instance):
    # Reuse selection/status with public instance labels, retaining Account IDs.
    identities = {
        value["login"]["instance"]: key
        for key, value in config["accounts"].items()
        if value.get("login") and value["login"]["owner"] == owner
    }
    accounts = {key: config["accounts"][key] for key in identities.values()}
    if instance is not None and instance not in identities:
        raise OAuthError("unknown instance")
    return choose({**config, "accounts": accounts},
                  identities[instance] if instance is not None else None,
                  display_names={key: label for label, key in identities.items()})


def main():
    parser = argparse.ArgumentParser(prog="mcp-oauth")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--owner")
    parser.add_argument("command", choices=("daemon", "login", "refresh", "status"))
    parser.add_argument("account", nargs="?")
    args = parser.parse_args()
    try:
        config = manifest(args.manifest)
        if args.command in ("daemon", "refresh") and args.account is None and len(config["accounts"]) > 1:
            raise OAuthError("supply an explicit account name")
        if args.owner is not None and args.command != "login":
            raise OAuthError("owner selection requires login")
        name = (owner_selection(config, args.owner, args.account)
                if args.owner is not None else choose(config, args.account))
        account = Account(config["backend"], name, config["accounts"][name])
        if args.command == "daemon":
            # Private input set only by the generated backend wrapper, never a flag.
            run(account, os.environ.get("MCP_OAUTH_WRAPPER", ""))
            return 0
        if args.command == "login":
            login(account)
        elif args.command == "refresh":
            account.refresh()
        print(account.status())
        return 0
    except OAuthError as error:
        print(f"mcp-oauth: {error}", file=sys.stderr)
    except (OSError, RecursionError, ValueError):
        print("mcp-oauth: cannot read account configuration or state", file=sys.stderr)
    except KeyboardInterrupt:
        print("mcp-oauth: cancelled", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
