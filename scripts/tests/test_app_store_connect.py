import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("app_store_connect", str(Path(__file__).resolve().parents[1] / "app-store-connect"))
spec = importlib.util.spec_from_loader(loader.name, loader)
asc = importlib.util.module_from_spec(spec)
loader.exec_module(asc)


class ScreenshotProcessingTests(unittest.TestCase):
    def test_a_draft_screenshot_finishes_at_the_documented_parent_state(self):
        for state in ("ACTIVE", "PARENT_PREPARE_FOR_SUBMISSION", "PARENT_IN_REVIEW", "PARENT_APPROVED"):
            with self.subTest(state=state):
                with patch.object(asc, "api", return_value={"attributes": {"state": state}}):
                    self.assertTrue(asc.processed_screenshots(["screenshot"]))

    def test_processing_is_pending_and_failed_processing_is_reported(self):
        for state in ("ASSET_PROCESSING", "UPLOADING", "UNKNOWN_NEW_STATE"):
            with self.subTest(state=state), patch.object(asc, "api", return_value={"attributes": {"state": state}}):
                self.assertIsNone(asc.processed_screenshots(["screenshot"]))
        with patch.object(asc, "api", return_value={"attributes": {"state": "FAILED", "stateDetails": "Invalid image"}}):
            with self.assertRaisesRegex(SystemExit, "Invalid image"):
                asc.processed_screenshots(["screenshot"])


class BuildIdentityTests(unittest.TestCase):
    def test_pending_uploads_count_toward_the_next_global_build(self):
        with patch.object(asc, "api", side_effect=[
            [{"attributes": {"version": "10"}}],
            [{"attributes": {"cfBundleVersion": "12"}}],
        ]):
            self.assertEqual(13, asc.next_build_number("app"))

    def test_dotted_builds_advance_the_global_integer_train(self):
        with patch.object(asc, "api", side_effect=[
            [{"attributes": {"version": "20261027.2.9"}}],
            [{"attributes": {"cfBundleVersion": "20261027.3"}}],
        ]):
            self.assertEqual(20261028, asc.next_build_number("app"))

    def test_a_retry_reuses_the_exact_dotted_build_for_each_platform(self):
        for platform in ("IOS", "MAC_OS"):
            with self.subTest(platform=platform), patch.object(asc, "api", side_effect=[
                [{"attributes": {"version": "12.9"}}],
                [{"attributes": {"cfBundleVersion": "12.10", "state": {"state": "COMPLETE"}}}],
            ]) as api:
                self.assertEqual(("12.10", True), asc.reserve_build("app", platform, "0.20.0", "12", True))
                self.assertEqual(platform, api.call_args_list[0].kwargs["filter[preReleaseVersion.platform]"])
                self.assertEqual(platform, api.call_args_list[1].kwargs["filter[platform]"])

    def test_an_uncertain_upload_times_out_without_allocating_another_build(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=[]), \
             patch.object(asc.time, "monotonic", side_effect=[0, 901]), \
             patch.object(asc, "next_build_number") as allocate:
            with self.assertRaisesRegex(SystemExit, "do not upload again blindly"):
                asc.reserve_build("app", "MAC_OS", "0.20.0", "12", True)
            allocate.assert_not_called()

    def test_a_first_attempt_uploads_beside_an_older_build_of_the_same_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["1"]) as existing, \
             patch.object(asc, "next_build_number", return_value=9106):
            self.assertEqual((9107, False), asc.reserve_build("app", "IOS", "1.0.0", "9107", False))
            existing.assert_not_called()

    def test_a_retry_never_selects_an_older_build_of_the_same_version(self):
        with patch.object(asc, "uploaded_build_numbers", return_value=["1"]), \
             patch.object(asc.time, "monotonic", side_effect=[0, 901]):
            with self.assertRaisesRegex(SystemExit, "do not upload again blindly"):
                asc.reserve_build("app", "IOS", "1.0.0", "9107", True)

    def test_acceptance_filters_the_exact_uploaded_build(self):
        with patch.object(asc, "api", return_value=[]) as api:
            self.assertIsNone(asc.processed_build("app", "1.3.2", "11", "MAC_OS"))
            self.assertEqual("11", api.call_args.kwargs["filter[version]"])
            self.assertEqual("1.3.2", api.call_args.kwargs["filter[preReleaseVersion.version]"])
            self.assertEqual("MAC_OS", api.call_args.kwargs["filter[preReleaseVersion.platform]"])

    def test_all_pages_are_read_before_selecting_a_build_number(self):
        pages = [
            {"data": [{"id": "first"}], "links": {"next": asc.API + "builds?cursor=next"}},
            {"data": [{"id": "last"}], "links": {"next": None}},
        ]
        with patch.object(asc, "token", return_value="fixture"), patch.object(asc, "send", side_effect=[json.dumps(p).encode() for p in pages]):
            self.assertEqual([{"id": "first"}, {"id": "last"}], asc.api("GET", "builds"))


class DraftVersionTests(unittest.TestCase):
    def test_a_never_released_draft_is_renamed_to_the_tag_even_when_it_looks_newer(self):
        draft = {"id": "draft", "attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION", "versionString": "1.0"}}
        renamed = {"attributes": {"versionString": "0.20.0", "releaseType": "MANUAL"}}
        with patch.object(asc, "api", side_effect=[[draft], renamed]) as api:
            self.assertEqual(("draft", False), asc.draft_version("app", "IOS", "0.20.0"))
            self.assertEqual("0.20.0", api.call_args_list[1].args[2]["attributes"]["versionString"])

    def test_a_draft_newer_than_a_released_version_is_refused(self):
        released = {"attributes": {"appVersionState": "READY_FOR_DISTRIBUTION", "versionString": "0.19.0"}}
        draft = {"id": "draft", "attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION", "versionString": "1.0"}}
        with patch.object(asc, "api", return_value=[released, draft]):
            with self.assertRaisesRegex(SystemExit, "newer"):
                asc.draft_version("app", "IOS", "0.20.0")

    def test_each_platform_prepares_its_own_exact_build_without_replacing_existing_media(self):
        for platform, number in (("IOS", "9101"), ("MAC_OS", "9102")):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                if platform == "IOS":
                    (root / "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE").mkdir()
                    (root / "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE/01.png").write_bytes(b"image")
                draft = {"id": "draft", "attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION", "versionString": "1.0"}}
                renamed = {"attributes": {"versionString": "0.19.2", "releaseType": "MANUAL"}}
                with patch.object(asc, "api", side_effect=[
                    [draft], renamed, {"id": "library"}, [],
                    [{"id": "selected", "attributes": {"processingState": "VALID"}}], None,
                ]) as api, patch.object(asc, "upload", return_value="image"):
                    asc.app_store("app", platform, "0.19.2", number, root, "notes")
                self.assertEqual(platform, api.call_args_list[0].kwargs["filter[platform]"])
                self.assertEqual({"versionString": "0.19.2", "releaseType": "MANUAL"}, api.call_args_list[1].args[2]["attributes"])
                self.assertEqual(platform, api.call_args_list[4].kwargs["filter[preReleaseVersion.platform]"])
                self.assertEqual(number, api.call_args_list[4].kwargs["filter[version]"])
                self.assertEqual(("PATCH", "appStoreVersions/draft/relationships/build", {"type": "builds", "id": "selected"}), api.call_args_list[5].args)

    def test_a_platform_version_in_review_is_left_untouched(self):
        draft = {"id": "reviewing", "attributes": {"appVersionState": "IN_REVIEW", "versionString": "0.19.2"}}
        with tempfile.TemporaryDirectory() as temporary, patch.object(asc, "api", return_value=[draft]) as api:
            asc.app_store("app", "MAC_OS", "0.19.3", "9104", temporary, "notes")
        self.assertEqual(1, api.call_count)


class UploadCleanupTests(unittest.TestCase):
    def test_a_failed_transfer_reclaims_its_reserved_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "display").mkdir()
            (root / "display/01.png").write_bytes(b"fixture image")
            reservation = {"id": "reserved", "attributes": {"uploadOperations": [
                {"url": "https://example.com/upload", "offset": 0, "length": 13, "method": "PUT", "requestHeaders": []}
            ]}}
            with patch.object(asc, "draft_version", return_value=("version", False)), \
                 patch.object(asc, "api", side_effect=[{"id": "library"}, reservation]), \
                 patch.object(asc, "send", side_effect=asc.RequestFailed("transfer failed")), \
                 patch.object(asc, "delete_unplaced") as cleanup:
                with self.assertRaisesRegex(asc.RequestFailed, "transfer failed"):
                    asc.app_store("app", "IOS", "1.3.2", "11", root, "notes")
                cleanup.assert_called_once_with(["reserved"])
