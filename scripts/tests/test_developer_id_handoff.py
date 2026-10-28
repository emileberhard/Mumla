import hashlib
import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("handoff", Path(__file__).resolve().parents[2] / ".github/scripts/developer-id-handoff.py")
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class DeveloperIDReceiptTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"source_repository": "example/mumla", "version": "1.2.3", "commit": "a" * 40,
                         "build": "42", "source_run": "123", "source_attempt": "2", "deploy_run": "456"}
        self.dmg = b"synthetic notarized artifact fixture"
        self.receipt = self.expected | {"origin": handoff.ORIGIN, "sha256": hashlib.sha256(self.dmg).hexdigest()}

    def test_preflight_requires_the_private_active_deployment_workflow(self):
        for private, state, allowed in ((True, "active", True), (False, "active", False), (True, "disabled_manually", False)):
            repository = {"full_name": handoff.DEPLOY, "private": private}
            workflow = {"path": ".github/workflows/developer-id.yml", "state": state}
            with self.subTest(private=private, state=state), patch.object(handoff, "document", side_effect=[repository, workflow]):
                if allowed:
                    handoff.preflight()
                else:
                    with self.assertRaisesRegex(ValueError, "not configured"):
                        handoff.preflight()

    def test_receipt_requires_every_release_identity_field(self):
        for key in self.expected:
            with self.subTest(key=key), patch.object(handoff, "public_file") as download:
                with self.assertRaisesRegex(ValueError, "exact release"):
                    handoff.verify_receipt(self.receipt | {key: "different"}, self.expected)
                download.assert_not_called()

    def test_public_manifest_and_actual_download_must_match_the_private_receipt(self):
        for manifest_change, dmg, error in (({}, self.dmg, None), ({"commit": "b" * 40}, self.dmg, "manifest"),
                                             ({}, b"another artifact", "digest")):
            with self.subTest(manifest_change=manifest_change, dmg=dmg), \
                 patch.object(handoff, "public_file", return_value=json.dumps(self.receipt | manifest_change).encode()), \
                 patch.object(handoff.urllib.request, "urlopen", return_value=io.BytesIO(dmg)):
                if error:
                    with self.assertRaisesRegex(ValueError, error):
                        handoff.verify_receipt(self.receipt, self.expected)
                else:
                    handoff.verify_receipt(self.receipt, self.expected)

    def test_the_receipt_cannot_choose_the_download_origin(self):
        with self.assertRaisesRegex(ValueError, "download identity"):
            handoff.verify_receipt(self.receipt | {"origin": "https://example.invalid/"}, self.expected)
