#!/usr/bin/env python3
"""Read update-PR provenance and activity from GitHub."""

import argparse
import json
import os
import subprocess
import sys


def github(*arguments):
    return json.loads(subprocess.check_output(["gh", "api", *arguments], text=True))


def bot_push(activities, branch, head):
    # Repository activity records the authenticated pusher, separately from
    # the freely chosen author/committer identities inside a Git commit.
    return isinstance(activities, list) and len(activities) == 1 and (
        activities[0].get("activity_type") in {"branch_creation", "force_push", "push"}
        and (activities[0].get("actor") or {}).get("login") == "nix-agentic-tools-bot[bot]"
        and activities[0].get("after") == head
        and activities[0].get("ref") == "refs/heads/" + branch
    )


def bot_thread(thread, allowed):
    comments = thread["comments"]
    # Preserve rather than infer safety from a truncated discussion.
    return bool(comments["nodes"]) and not comments["pageInfo"]["hasNextPage"] and all(
        (comment.get("author") or {}).get("login") in allowed
        for comment in comments["nodes"]
    )


def bot_review_threads(repo, number, allowed):
    owner, name = repo.split("/", 1)
    query = """
      query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                comments(first: 100) {
                  pageInfo { hasNextPage }
                  nodes { author { login } }
                }
              }
            }
          }
        }
      }
    """
    cursor = None
    while True:
        arguments = ["graphql", "-f", "query=" + query, "-f", "owner=" + owner, "-f", "name=" + name, "-F", "number=" + str(number)]
        if cursor:
            arguments += ["-f", "cursor=" + cursor]
        response = github(*arguments)
        if response.get("errors"):
            return False
        threads = response["data"]["repository"]["pullRequest"]["reviewThreads"]
        if not all(bot_thread(thread, allowed) for thread in threads["nodes"]):
            return False
        if not threads["pageInfo"]["hasNextPage"]:
            return True
        next_cursor = threads["pageInfo"]["endCursor"]
        if not next_cursor or next_cursor == cursor:
            return False
        cursor = next_cursor


def auto_merge_retry(events, allowed):
    """Classify the latest auto-merge event for an unchanged bot PR."""
    if not isinstance(events, list) or len(events) > 1:
        raise ValueError("expected at most one latest auto-merge event")
    if not events:
        return "allowed"

    event = events[0]
    event_type = event.get("__typename")
    if event_type == "AutoMergeEnabledEvent":
        return "allowed"
    if event_type != "AutoMergeDisabledEvent":
        raise ValueError(f"unexpected auto-merge event type: {event_type!r}")

    actor = (event.get("actor") or {}).get("login")
    disabler = (event.get("disabler") or {}).get("login")
    if disabler:
        return "allowed" if disabler in allowed else "human-disabled"
    if actor in allowed:
        return "allowed"
    # GitHub's automatic disables have no User-valued disabler and carry a
    # reason. Refuse an unclassified disabled event rather than guessing.
    if event.get("reason") or event.get("reasonCode"):
        return "allowed"
    raise ValueError("disabled event has neither a disabler nor an automatic reason")


def auto_merge_retry_status(repo, number):
    owner, name = repo.split("/", 1)
    query = """
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            timelineItems(last: 1, itemTypes: [AUTO_MERGE_ENABLED_EVENT, AUTO_MERGE_DISABLED_EVENT]) {
              nodes {
                __typename
                ... on AutoMergeEnabledEvent {
                  actor { login }
                  enabler { login }
                }
                ... on AutoMergeDisabledEvent {
                  actor { login }
                  disabler { login }
                  reason
                  reasonCode
                }
              }
            }
          }
        }
      }
    """
    response = github(
        "graphql",
        "-f",
        "query=" + query,
        "-f",
        "owner=" + owner,
        "-f",
        "name=" + name,
        "-F",
        "number=" + str(number),
    )
    if response.get("errors"):
        raise ValueError(response["errors"])
    events = response["data"]["repository"]["pullRequest"]["timelineItems"]["nodes"]
    allowed = {"app/nix-agentic-tools-bot", "nix-agentic-tools-bot", "nix-agentic-tools-bot[bot]"}
    return auto_merge_retry(events, allowed)


def close_retry(events, allowed):
    """Classify who performed the latest close of a closed update PR."""
    if not isinstance(events, list) or len(events) != 1:
        raise ValueError("expected exactly one latest close event")
    event = events[0]
    if event.get("__typename") != "ClosedEvent":
        raise ValueError("unexpected close event type")
    actor = (event.get("actor") or {}).get("login")
    if not actor:
        raise ValueError("close event has no actor")
    return "automatic" if actor in allowed else "human"


def close_retry_status(repo, number):
    owner, name = repo.split("/", 1)
    query = """
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            timelineItems(last: 1, itemTypes: [CLOSED_EVENT]) {
              nodes {
                __typename
                ... on ClosedEvent { actor { login } }
              }
            }
          }
        }
      }
    """
    response = github(
        "graphql",
        "-f",
        "query=" + query,
        "-f",
        "owner=" + owner,
        "-f",
        "name=" + name,
        "-F",
        "number=" + str(number),
    )
    if response.get("errors"):
        raise ValueError(response["errors"])
    events = response["data"]["repository"]["pullRequest"]["timelineItems"]["nodes"]
    allowed = {"app/nix-agentic-tools-bot", "nix-agentic-tools-bot", "nix-agentic-tools-bot[bot]"}
    return close_retry(events, allowed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    push = sub.add_parser("push")
    push.add_argument("branch")
    push.add_argument("head")
    auto_merge = sub.add_parser("auto-merge-retry")
    auto_merge.add_argument("number", type=int)
    close = sub.add_parser("close-retry")
    close.add_argument("number", type=int)
    reviews = sub.add_parser("reviews")
    reviews.add_argument("number", type=int)
    reviews.add_argument("allowed", type=json.loads)
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    try:
        if args.command == "auto-merge-retry":
            status = auto_merge_retry_status(repo, args.number)
            if status == "human-disabled":
                print("human-disabled")
                return 2
            verified = status == "allowed"
        elif args.command == "close-retry":
            status = close_retry_status(repo, args.number)
            if status == "human":
                print("human")
                return 2
            verified = status == "automatic"
        elif args.command == "push":
            activities = github("--method", "GET", f"repos/{repo}/activity", "-f", "ref=refs/heads/" + args.branch, "-f", "direction=desc", "-F", "per_page=1")
            verified = bot_push(activities, args.branch, args.head)
        else:
            verified = bot_review_threads(repo, args.number, args.allowed)
    except (KeyError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"::warning::Could not verify GitHub {args.command} metadata: {error}", file=sys.stderr)
        return 1
    return 0 if verified else 1


if __name__ == "__main__":
    sys.exit(main())
