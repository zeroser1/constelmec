"""Offline unit checks for the backup workflow (no credentials or network)."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from backup_to_drive import create_archive, find_or_create_backup_folder, safe_name, storage_objects


class BackupTests(unittest.TestCase):
    def test_storage_path_traversal_rejected(self):
        for value in ("../secret", "/absolute", "a/../b", "a//b", "a\\b", ""):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    safe_name(value)
        self.assertEqual(safe_name("photos/visit-1.jpg").as_posix(), "photos/visit-1.jpg")

    def test_storage_recursive_listing(self):
        response = Mock()
        response.raise_for_status.return_value = None
        response.json.side_effect = [
            [{"name": "folder", "id": None}, {"name": "root.jpg", "id": "id1"}],
            [{"name": "nested.jpg", "id": "id2"}],
        ]
        http = Mock()
        http.post.return_value = response
        found = list(storage_objects(http, "https://example.supabase.co",
                                     {"apikey": "test"}, "bucket"))
        self.assertEqual(found, ["folder/nested.jpg", "root.jpg"])
        self.assertEqual(http.post.call_count, 2)

    def test_drive_file_scope_creates_app_owned_folder(self):
        listing = Mock()
        listing.raise_for_status.return_value = None
        listing.json.return_value = {"files": []}
        created = Mock()
        created.raise_for_status.return_value = None
        created.json.return_value = {"id": "folder-123"}
        http = Mock()
        http.get.return_value = listing
        http.post.return_value = created
        self.assertEqual(find_or_create_backup_folder(http, "access-token"), "folder-123")
        args = http.post.call_args
        self.assertEqual(args.kwargs["json"]["appProperties"],
                         {"constelmec_backup": "production"})

    def test_drive_file_scope_reuses_app_owned_folder(self):
        listing = Mock()
        listing.raise_for_status.return_value = None
        listing.json.return_value = {"files": [{"id": "folder-456"}]}
        http = Mock()
        http.get.return_value = listing
        self.assertEqual(find_or_create_backup_folder(http, "access-token"), "folder-456")
        http.post.assert_not_called()

    def test_archive_encrypts_and_verifies(self):
        import pyzipper
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = root / "payload"
            payload.mkdir()
            (payload / "schema.sql").write_text("select 1;", encoding="utf-8")
            (payload / "managed-schema.sql").write_text(
                "CREATE POLICY fixture ON storage.objects FOR SELECT TO authenticated USING (false);",
                encoding="utf-8",
            )
            archive = root / "backup.zip"
            count = create_archive(payload, "a-strong-test-password-32-characters",
                                   {"project_ref": "test"}, archive)
            self.assertEqual(count, 2)
            with pyzipper.AESZipFile(archive) as zipped:
                zipped.setpassword(b"a-strong-test-password-32-characters")
                self.assertEqual(zipped.read("schema.sql"), b"select 1;")
                manifest = json.loads(zipped.read("manifest.json"))
                self.assertEqual(
                    {item["path"] for item in manifest["files"]},
                    {"schema.sql", "managed-schema.sql"},
                )
                self.assertEqual(
                    zipped.read("managed-schema.sql"), (payload / "managed-schema.sql").read_bytes()
                )


if __name__ == "__main__":
    unittest.main()
