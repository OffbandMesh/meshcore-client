"""Polls Apple's notary service for one submission until it settles or a deadline passes.

Usage: notary-wait.py <submission-id> <deadline-minutes>
Env:   P8 (path to the App Store Connect .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID

Exit 0 only on Accepted. Invalid/Rejected print Apple's log and exit 1. Still
In Progress at the deadline exits 1 with how to resume: the submission keeps
going at Apple, and "Re-run failed jobs" polls the same id again (#1109).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://appstoreconnect.apple.com/notary/v2/submissions/"
POLL_SECONDS = 60

submission_id = sys.argv[1]
deadline = time.time() + int(sys.argv[2]) * 60
with open(os.environ["P8"], encoding="utf-8") as fh:
    private_key = fh.read()


def get(url, auth=True):
    headers = {}
    if auth:
        now = int(time.time())
        token = jwt.encode(
            {"iss": os.environ["NOTARY_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
            private_key, algorithm="ES256", headers={"kid": os.environ["NOTARY_KEY_ID"], "typ": "JWT"},
        )
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


while True:
    try:
        body = get(API + submission_id)
        status = body["data"]["attributes"]["status"]
    except (KeyError, TypeError):
        print(f"::error::Unexpected notary API response for {submission_id}: {json.dumps(body)[:500]}")
        sys.exit(1)
    except urllib.error.HTTPError as error:
        if error.code < 500:
            print(f"::error::Notary API returned HTTP {error.code} for {submission_id}.")
            sys.exit(1)
        status = f"HTTP {error.code}, retrying"
    except urllib.error.URLError as error:
        status = f"network error ({error.reason}), retrying"
    print(time.strftime("%H:%M:%S"), status, flush=True)

    if status == "Accepted":
        sys.exit(0)
    if status in ("Invalid", "Rejected"):
        print(f"::error::Apple returned {status} for notary submission {submission_id}.")
        log_url = get(API + submission_id + "/logs")["data"]["attributes"]["developerLogUrl"]
        print(json.dumps(get(log_url, auth=False), indent=2))
        sys.exit(1)
    if time.time() > deadline:
        print(f"::error::Notary submission {submission_id} is still In Progress at Apple. "
              "Nothing is lost: the signed app is kept as an artifact of this run. "
              "Use 'Re-run failed jobs' later to check the same submission again.")
        sys.exit(1)
    time.sleep(POLL_SECONDS)
