"""Guards on the two workflows that put a release on Play (#1087, #1088).

The refusals themselves were proven live in A3 (#1086): Google refuses a
sign-in from outside play-release, GitHub refuses a branch asking for it, and
`gh attestation verify` refuses a wrong ref, a wrong signer and an unrecorded
file. These tests keep the workflows wired to those checks.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import play_release as p

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"


def jobs(text: str) -> dict[str, str]:
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"^  ([a-z][a-z0-9-]*):\n", body, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


class ReleaseSigned(unittest.TestCase):
    def setUp(self):
        self.android = jobs((WORKFLOWS / "release-signed.yml").read_text("utf-8"))["android"]

    def test_android_job_records_the_aab_provenance(self):
        self.assertRegex(
            self.android,
            r"uses: actions/attest-build-provenance@v\d+\s+with:\s+"
            r"subject-path: build/app/outputs/bundle/release/app-release\.aab",
        )

    def test_android_job_can_write_the_record(self):
        for perm in ("contents: read", "id-token: write", "attestations: write"):
            self.assertIn(perm, self.android)


class PlayPublish(unittest.TestCase):
    def setUp(self):
        self.text = (WORKFLOWS / "play-publish.yml").read_text("utf-8")
        self.jobs = jobs(self.text)
        self.trigger = self.text.split("\non:\n", 1)[1].split("\nconcurrency:", 1)[0]

    def test_dispatch_is_the_only_trigger(self):
        self.assertIn("workflow_dispatch:", self.trigger)
        for other in ("pull_request", "push:", "schedule", "workflow_run", "release:"):
            self.assertNotIn(other, self.trigger)

    def test_targets_and_rollouts_match_the_tool(self):
        target = re.search(r"target:.*?options: \[(.*?)\]", self.trigger, re.S).group(1)
        rollout = re.search(r"rollout:.*?options: \[(.*?)\]", self.trigger, re.S).group(1)
        self.assertEqual(sorted(re.findall(r"[a-z]+", target)), sorted(p.TRACKS))
        self.assertEqual(re.findall(r'"(\w+)"', rollout), list(p.ROLLOUTS))

    def test_one_queue_for_the_app_never_cancelled(self):
        self.assertRegex(self.text, r"concurrency:\s+group: play-publish\s+cancel-in-progress: false")

    def test_only_the_publish_job_can_get_a_google_token(self):
        self.assertEqual(set(self.jobs), {"verify", "publish"})
        self.assertNotIn("id-token", self.jobs["verify"])
        self.assertNotIn("environment:", self.jobs["verify"])
        self.assertIn("environment: play-release", self.jobs["publish"])
        self.assertIn("id-token: write", self.jobs["publish"])
        self.assertIn("needs: verify", self.jobs["publish"])

    def test_verify_refuses_anything_but_a_v_tag_on_main(self):
        verify = self.jobs["verify"]
        self.assertIn('refs/tags/v*)', verify)
        self.assertIn('git merge-base --is-ancestor "$GITHUB_SHA" origin/main', verify)

    def test_verify_checks_the_bundle_came_from_the_signed_run_at_this_tag(self):
        verify = self.jobs["verify"]
        self.assertIn("gh attestation verify", verify)
        self.assertIn('--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/release-signed.yml"', verify)
        self.assertIn('--source-ref "$GITHUB_REF"', verify)
        self.assertIn('--source-digest "$GITHUB_SHA"', verify)
        self.assertIn("--deny-self-hosted-runners", verify)

    def test_publish_sends_only_the_bundle_verify_checked(self):
        self.assertIn("aab_sha256", self.jobs["verify"])
        self.assertIn("needs.verify.outputs.aab_sha256", self.jobs["publish"])

    def test_google_token_is_play_scoped_and_never_a_file(self):
        publish = self.jobs["publish"]
        self.assertIn("uses: google-github-actions/auth@", publish)
        self.assertIn("token_format: access_token", publish)
        self.assertIn("access_token_scopes: https://www.googleapis.com/auth/androidpublisher", publish)
        self.assertIn("create_credentials_file: false", publish)
        self.assertNotIn("credentials_json", self.text)


if __name__ == "__main__":
    unittest.main()
