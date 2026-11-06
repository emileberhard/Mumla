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

NOTES = "Fixed a thing.\n\n[sv]\nFixade en sak.\n"


def write_listing(root, locales=("en-US", "sv")):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / "primary_locale.txt").write_text("en-US\n")
    (root / "support_url.txt").write_text("https://example.com/support\n")
    (root / "privacy_url.txt").write_text("https://example.com/privacy\n")
    for locale in locales:
        (root / locale).mkdir(parents=True)
        (root / locale / "name.txt").write_text(f"Name {locale}\n")
        (root / locale / "subtitle.txt").write_text(f"Subtitle {locale}\n")
        (root / locale / "keywords.txt").write_text("one,two\n")
        (root / locale / "description.txt").write_text(f"About {locale}.\n\nTerms of Use: {asc.TERMS_OF_USE}\n")
    return root


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

    def test_each_platform_prepares_its_own_exact_build_and_tracked_listing(self):
        for platform, number in (("IOS", "9101"), ("MAC_OS", "9102")):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                listing = write_listing(Path(temporary) / "listing")
                shots = Path(temporary) / "shots"
                if platform == "IOS":
                    for locale in ("en-US", "sv"):
                        (shots / locale / "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE").mkdir(parents=True)
                        (shots / locale / "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE/01.png").write_bytes(locale.encode())
                calls = []

                def api(method, path, data=None, **params):
                    calls.append((method, path, data, params))
                    responses = {
                        ("GET", "apps/app/appStoreVersions"): [{"id": "draft", "attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION", "versionString": "1.0"}}],
                        ("PATCH", "appStoreVersions/draft"): {"attributes": {"versionString": "0.19.2", "releaseType": "MANUAL"}},
                        ("GET", "apps/app/assetLibrary"): {"id": "library"},
                        ("GET", "apps/app"): {"attributes": {"primaryLocale": "en-US"}},
                        ("GET", "apps/app/appInfos"): [{"id": "live-info", "attributes": {"state": "READY_FOR_DISTRIBUTION"}},
                                                       {"id": "info", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}],
                        ("GET", "appInfos/info/appInfoLocalizations"): [{"id": "info-en", "attributes": {"locale": "en-US"}}],
                        ("POST", "appInfoLocalizations"): {"id": "info-sv"},
                        ("GET", "appStoreVersions/draft/appStoreVersionLocalizations"): [{"id": "version-en", "attributes": {"locale": "en-US"}}],
                        ("POST", "appStoreVersionLocalizations"): {"id": "version-sv"},
                        ("GET", "builds"): [{"id": "selected", "attributes": {"processingState": "VALID"}}],
                    }
                    return responses.get((method, path))

                with patch.object(asc, "api", side_effect=api), \
                     patch.object(asc, "upload", side_effect=lambda library, slide, created: slide.read_text()), \
                     patch.object(asc, "place", return_value=([], set())) as place:
                    asc.app_store("app", platform, "0.19.2", number, shots, listing, NOTES)
                writes = {(method, path): data for method, path, data, _ in calls if method != "GET"}
                self.assertEqual({"versionString": "0.19.2", "releaseType": "MANUAL"}, writes[("PATCH", "appStoreVersions/draft")]["attributes"])
                self.assertEqual({"locale": "sv", "name": "Name sv", "subtitle": "Subtitle sv", "privacyPolicyUrl": "https://example.com/privacy"},
                                 writes[("POST", "appInfoLocalizations")]["attributes"])
                self.assertEqual({"type": "appInfos", "id": "info"}, writes[("POST", "appInfoLocalizations")]["relationships"]["appInfo"]["data"])
                self.assertEqual("Name en-US", writes[("PATCH", "appInfoLocalizations/info-en")]["attributes"]["name"])
                self.assertEqual({"description", "keywords", "supportUrl"}, set(writes[("PATCH", "appStoreVersionLocalizations/version-en")]["attributes"]))
                self.assertEqual("sv", writes[("POST", "appStoreVersionLocalizations")]["attributes"]["locale"])
                build = next(params for method, path, _, params in calls if path == "builds")
                self.assertEqual((platform, number), (build["filter[preReleaseVersion.platform]"], build["filter[version]"]))
                self.assertEqual({"type": "builds", "id": "selected"}, writes[("PATCH", "appStoreVersions/draft/relationships/build")])
                placed = sorted((call.args[0], call.args[1]) for call in place.call_args_list)
                self.assertEqual([("version-en", ["en-US"]), ("version-sv", ["sv"])] if platform == "IOS" else [], placed)

    def test_a_platform_version_in_review_is_left_untouched(self):
        draft = {"id": "reviewing", "attributes": {"appVersionState": "IN_REVIEW", "versionString": "0.19.2"}}
        with tempfile.TemporaryDirectory() as temporary, patch.object(asc, "api", return_value=[draft]) as api:
            asc.app_store("app", "MAC_OS", "0.19.3", "9104", temporary, write_listing(Path(temporary) / "listing"), NOTES)
        self.assertEqual(1, api.call_count)


class ListingTests(unittest.TestCase):
    def test_the_tracked_listing_is_valid(self):
        primary, _, locales = asc.read_listing(Path(__file__).resolve().parents[2] / "Apple/AppStore/listing")
        self.assertEqual("en-US", primary)
        self.assertIn("sv", locales)

    def test_a_description_without_the_terms_of_use_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            listing = write_listing(temporary)
            (listing / "sv/description.txt").write_text("Om appen.\n")
            with self.assertRaisesRegex(SystemExit, "Terms of Use"):
                asc.read_listing(listing)

    def test_release_notes_need_one_section_per_other_language(self):
        locales = {"en-US": {}, "sv": {}}
        self.assertEqual({"en-US": "Fixed a thing.", "sv": "Fixade en sak."}, asc.notes_by_locale(NOTES, "en-US", locales))
        for notes in ("Fixed a thing.\n", "Fixed a thing.\n[sv]\n\n", NOTES + "[de]\nEtwas.\n", NOTES + "[sv]\nIgen.\n", "[sv]\nBara svenska.\n"):
            with self.subTest(notes=notes), self.assertRaises(SystemExit):
                asc.notes_by_locale(notes, "en-US", locales)

    def test_testflight_and_github_get_the_primary_lines(self):
        self.assertEqual("Fixed a thing.", asc.localized_notes(NOTES)[None])

    def test_an_untracked_store_language_stops_before_writing(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append(path)
            return [{"id": "de", "attributes": {"locale": "de-DE"}}, {"id": "en", "attributes": {"locale": "en-US"}}]

        with patch.object(asc, "api", side_effect=api), self.assertRaisesRegex(SystemExit, "de-DE"):
            asc.sync_localizations("appStoreVersions/v/appStoreVersionLocalizations", "appStoreVersionLocalizations",
                                   "appStoreVersion", "appStoreVersions", "v", {"en-US": {"description": "About"}})
        self.assertEqual([], writes)


def submission(identifier, version, state):
    return {"id": identifier, "attributes": {"state": state},
            "relationships": {"appStoreVersionForReview": {"data": version and {"type": "appStoreVersions", "id": version}}}}


def item(identifier, version, state):
    return {"id": identifier, "attributes": {"state": state},
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version}}}}


LIVE = {"id": "live", "attributes": {"appVersionState": "READY_FOR_DISTRIBUTION", "versionString": "0.9.0"}}


class ReviewPolicyTests(unittest.TestCase):
    def test_a_rerun_leaves_its_own_version_in_review(self):
        with patch.object(asc, "api", return_value=[{"id": "review", "attributes": {
            "appVersionState": "WAITING_FOR_REVIEW", "versionString": "0.14.3"
        }}, LIVE]) as api:
            self.assertEqual((None, True), asc.draft_version("app", "IOS", "0.14.3"))
            self.assertEqual(["GET"], [call.args[0] for call in api.call_args_list])

    def test_a_newer_tag_withdraws_only_its_versions_submission_and_keeps_manual_release(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "apps/app/appStoreVersions":
                return [{"id": "review", "attributes": {"appVersionState": "IN_REVIEW", "versionString": "0.10.0"}}, LIVE]
            if path == "reviewSubmissions":
                return [submission("event", None, "IN_REVIEW"), submission("target", "review", "IN_REVIEW")]
            if path == "appStoreVersions/review" and method == "GET":
                return {"attributes": {"appVersionState": "DEVELOPER_REJECTED"}}
            if path == "appStoreVersions/review":
                return {"attributes": {"versionString": "0.14.3", "releaseType": "MANUAL"}}
            if path == "apps/app/subscriptionGroups":
                return []

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual(("review", True), asc.draft_version("app", "IOS", "0.14.3"))
        self.assertEqual([
            ("PATCH", "reviewSubmissions/target", {"type": "reviewSubmissions", "id": "target", "attributes": {"canceled": True}}),
            ("PATCH", "appStoreVersions/review", {"type": "appStoreVersions", "id": "review",
                                                  "attributes": {"releaseType": "MANUAL", "versionString": "0.14.3"}}),
        ], writes)

    def test_a_first_release_in_review_is_left_alone(self):
        with patch.object(asc, "api", return_value=[{"id": "review", "attributes": {
            "appVersionState": "IN_REVIEW", "versionString": "1.0.0"
        }}]) as api:
            self.assertEqual((None, False), asc.draft_version("app", "IOS", "1.0.1"))
            self.assertEqual(["GET"], [call.args[0] for call in api.call_args_list])

    def test_a_newer_tag_leaves_a_version_in_review_with_the_first_subscriptions(self):
        def api(method, path, data=None, **params):
            if method != "GET":
                raise AssertionError(f"{method} {path}")
            if path == "apps/app/appStoreVersions":
                return [{"id": "review", "attributes": {"appVersionState": "WAITING_FOR_REVIEW", "versionString": "1.2.0"}}, LIVE]
            if path == "apps/app/subscriptionGroups":
                return [{"id": "group"}]
            if path == "subscriptionGroups/group/subscriptions":
                return [{"attributes": {"state": "WAITING_FOR_REVIEW"}}, {"attributes": {"state": "WAITING_FOR_REVIEW"}}]

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual((None, True), asc.draft_version("app", "IOS", "1.2.1"))

    def test_a_rerun_leaves_a_prepared_version_for_the_first_subscriptions_website_submission(self):
        def api(method, path, data=None, **params):
            if method != "GET":
                raise AssertionError(f"{method} {path}")
            if path == "apps/app/appStoreVersions":
                return [{"id": "draft", "attributes": {"appVersionState": "READY_FOR_REVIEW", "versionString": "1.2.0"}}, LIVE]
            if path == "apps/app/subscriptionGroups":
                return [{"id": "group"}]
            if path == "subscriptionGroups/group/subscriptions":
                return [{"attributes": {"state": "READY_TO_SUBMIT"}}]

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual((None, True), asc.draft_version("app", "IOS", "1.2.0"))

    def test_a_newer_tag_deletes_its_versions_item_from_an_unsubmitted_draft(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path))
            if path == "reviewSubmissions":
                return [submission("draft", "review", "READY_FOR_REVIEW")]
            if path == "reviewSubmissions/draft/items":
                return [item("event", "other", "READY_FOR_REVIEW"), item("ours", "review", "READY_FOR_REVIEW")]
            if path == "appStoreVersions/review":
                return {"attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION"}}

        with patch.object(asc, "api", side_effect=api):
            asc.withdraw("app", "IOS", "review", "0.10.0")
        self.assertEqual([("DELETE", "reviewSubmissionItems/ours")], writes)

    def test_a_rerun_waits_for_a_cancellation_already_underway(self):
        states = iter(["IN_REVIEW", "DEVELOPER_REJECTED"])
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append(path)
            if path == "reviewSubmissions":
                return [submission("target", "review", "CANCELING")]
            if path == "appStoreVersions/review":
                return {"attributes": {"appVersionState": next(states)}}

        with patch.object(asc, "api", side_effect=api), patch.object(asc.time, "sleep"):
            asc.withdraw("app", "IOS", "review", "0.10.0")
        self.assertEqual([], writes)

    def test_a_rejected_version_resolves_its_own_item_in_its_own_submission(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions":
                return [submission("event", None, "UNRESOLVED_ISSUES"), submission("rejected", "version", "UNRESOLVED_ISSUES")]
            if path == "reviewSubmissions/rejected/items":
                return [item("other", "event-version", "REJECTED"), item("ours", "version", "REJECTED")]

        with patch.object(asc, "api", side_effect=api):
            asc.submit_for_review("app", "IOS", "version", "0.14.3")
        self.assertEqual([
            ("PATCH", "reviewSubmissionItems/ours", {"type": "reviewSubmissionItems", "id": "ours", "attributes": {"resolved": True}}),
            ("PATCH", "reviewSubmissions/rejected", {"type": "reviewSubmissions", "id": "rejected", "attributes": {"submitted": True}}),
        ], writes)

    def test_a_rerun_resumes_its_own_submission_instead_of_withdrawing_it(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path))
            if path == "apps/app/appStoreVersions":
                return [{"id": "draft", "attributes": {"appVersionState": "READY_FOR_REVIEW", "versionString": "0.14.3"}}, LIVE]
            if path == "reviewSubmissions":
                return [submission("resolved", "draft", "UNRESOLVED_ISSUES")]
            if path == "reviewSubmissions/resolved/items":
                return [item("ours", "draft", "READY_FOR_REVIEW")]
            if path == "apps/app/subscriptionGroups":
                return []

        with patch.object(asc, "api", side_effect=api):
            self.assertEqual((None, True), asc.draft_version("app", "IOS", "0.14.3"))
        self.assertEqual([("PATCH", "reviewSubmissions/resolved")], writes)

    def test_a_newer_tag_removes_its_version_from_an_unresolved_submission(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions":
                return [submission("unresolved", "review", "UNRESOLVED_ISSUES")]
            if path == "reviewSubmissions/unresolved/items":
                return [item("event", "other", "REJECTED"), item("ours", "review", "READY_FOR_REVIEW")]
            if path == "appStoreVersions/review":
                return {"attributes": {"appVersionState": "DEVELOPER_REJECTED"}}

        with patch.object(asc, "api", side_effect=api):
            asc.withdraw("app", "IOS", "review", "0.10.0")
        self.assertEqual([("PATCH", "reviewSubmissionItems/ours",
                           {"type": "reviewSubmissionItems", "id": "ours", "attributes": {"removed": True}})], writes)

    def test_an_unrelated_draft_submission_is_left_alone(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions" and method == "POST":
                return {"id": "new"}
            if path == "reviewSubmissions" and params.get("filter[state]") == "READY_FOR_REVIEW":
                return [{"id": "event-draft"}]
            if path == "reviewSubmissions/event-draft/items":
                return [item("event", "other", "READY_FOR_REVIEW")]
            return []

        with patch.object(asc, "api", side_effect=api):
            asc.submit_for_review("app", "IOS", "version", "0.14.3")
        self.assertEqual(["reviewSubmissions", "reviewSubmissionItems", "reviewSubmissions/new"], [path for _, path, _ in writes])

    def test_a_new_submission_carries_the_version(self):
        writes = []

        def api(method, path, data=None, **params):
            if method != "GET":
                writes.append((method, path, data))
            if path == "reviewSubmissions" and method == "POST":
                return {"id": "new"}
            if method == "GET":
                return []

        with patch.object(asc, "api", side_effect=api):
            asc.submit_for_review("app", "IOS", "version", "0.14.3")
        self.assertEqual(["reviewSubmissions", "reviewSubmissionItems", "reviewSubmissions/new"], [path for _, path, _ in writes])
        self.assertEqual({"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": "new"}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": "version"}}}, writes[1][2]["relationships"])
        self.assertEqual({"submitted": True}, writes[2][2]["attributes"])

class FirstSubscriptionTests(unittest.TestCase):
    def submits(self, states):
        def api(method, path, data=None, **params):
            if path == "apps/app/assetLibrary":
                return {"id": "library"}
            if path == "apps/app/subscriptionGroups":
                return [{"id": "group"}]
            if path == "subscriptionGroups/group/subscriptions":
                return [{"attributes": {"state": state}} for state in states]
            return []

        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(asc, "draft_version", return_value=("draft", True)), \
                patch.object(asc, "api", side_effect=api), \
                patch.object(asc, "update_listing", return_value={}) as listing, \
                patch.object(asc, "wait", return_value="build"), \
                patch.object(asc, "submit_for_review") as submit:
            asc.app_store("app", "MAC_OS", "1.2.0", "9105", temporary, write_listing(Path(temporary) / "listing"), NOTES)
        self.assertEqual({"en-US": "Fixed a thing.", "sv": "Fixade en sak."}, listing.call_args.args[5])
        return submit.called

    def test_the_first_subscriptions_leave_the_version_for_the_website(self):
        self.assertFalse(self.submits(["READY_TO_SUBMIT", "READY_TO_SUBMIT"]))

    def test_an_app_with_an_approved_subscription_submits_the_version(self):
        self.assertTrue(self.submits(["APPROVED", "READY_TO_SUBMIT"]))

    def test_an_app_without_subscriptions_to_submit_submits_the_version(self):
        self.assertTrue(self.submits(["MISSING_METADATA"]))


class UploadCleanupTests(unittest.TestCase):
    def test_a_failed_transfer_reclaims_its_reserved_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "shots"
            (root / "en-US/display").mkdir(parents=True)
            (root / "en-US/display/01.png").write_bytes(b"fixture image")
            reservation = {"id": "reserved", "attributes": {"uploadOperations": [
                {"url": "https://example.com/upload", "offset": 0, "length": 13, "method": "PUT", "requestHeaders": []}
            ]}}
            with patch.object(asc, "draft_version", return_value=("version", False)), \
                 patch.object(asc, "api", side_effect=[{"id": "library"}, reservation]), \
                 patch.object(asc, "send", side_effect=asc.RequestFailed("transfer failed")), \
                 patch.object(asc, "delete_unplaced") as cleanup:
                with self.assertRaisesRegex(asc.RequestFailed, "transfer failed"):
                    asc.app_store("app", "IOS", "1.3.2", "11", root, write_listing(Path(temporary) / "listing", ["en-US"]), "Fixed a thing.")
                cleanup.assert_called_once_with(["reserved"])
