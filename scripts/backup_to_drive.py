#!/usr/bin/env python3
"""Encrypted backup of Supabase database dumps and Storage to Google Drive."""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from urllib.parse import quote

import pyzipper
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

PROJECT_REF = "xpguxfttlxqpdlbhsjud"
CHUNK_SIZE = 8 * 1024 * 1024
PAGE_SIZE = 1000


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Required secret/config missing: {name}")
    return value


def digest(path: Path, algorithm: str) -> str:
    h = hashlib.new(algorithm)
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def safe_name(value: str) -> PurePosixPath:
    if not value or value.startswith("/") or "\\" in value or "\x00" in value:
        raise ValueError("Unsafe Storage object name")
    if any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError("Unsafe Storage path segments")
    return PurePosixPath(value)


def session() -> requests.Session:
    s = requests.Session()
    retries = Retry(total=4, connect=4, read=4, backoff_factor=1,
                    status_forcelist=[429, 500, 502, 503, 504],
                    allowed_methods=frozenset(["GET", "POST", "PUT"]))
    s.mount("https://", HTTPAdapter(max_retries=retries))
    return s


def storage_objects(s: requests.Session, base: str, headers: dict, bucket: str):
    visited = set()

    def walk(prefix: str):
        if prefix in visited:
            raise RuntimeError("Storage prefix loop")
        visited.add(prefix)
        offset = 0
        while True:
            r = s.post(f"{base}/storage/v1/object/list/{quote(bucket, safe='')}",
                       headers=headers,
                       json={"prefix": prefix, "limit": PAGE_SIZE, "offset": offset,
                             "sortBy": {"column": "name", "order": "asc"}}, timeout=60)
            r.raise_for_status()
            items = r.json()
            if not isinstance(items, list):
                raise RuntimeError("Unexpected Storage listing response")
            for item in items:
                name = item.get("name")
                if not isinstance(name, str):
                    raise RuntimeError("Storage item without name")
                full = f"{prefix}{name}"
                safe_name(full.rstrip("/"))
                if item.get("id") is None:
                    yield from walk(full.rstrip("/") + "/")
                else:
                    yield full
            if len(items) < PAGE_SIZE:
                break
            offset += len(items)

    yield from walk("")


def download_storage(s: requests.Session, base: str, key: str, directory: Path):
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    r = s.get(f"{base}/storage/v1/bucket", headers=headers, timeout=60)
    r.raise_for_status()
    buckets = r.json()
    if isinstance(buckets, dict) and "buckets" in buckets:
        buckets = buckets["buckets"]
    if not isinstance(buckets, list):
        raise RuntimeError("Unexpected bucket listing response")
    entries = []
    for bucket in buckets:
        bid = bucket.get("id")
        if not isinstance(bid, str) or not re.fullmatch(r"[a-zA-Z0-9_.-]+", bid):
            raise RuntimeError("Unexpected bucket id")
        for name in storage_objects(s, base, headers, bid):
            path = directory / "storage" / bid / Path(*safe_name(name).parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            url = f"{base}/storage/v1/object/{quote(bid, safe='')}/{quote(name, safe='/')}"
            with s.get(url, headers=headers, stream=True, timeout=(30, 180)) as response:
                response.raise_for_status()
                with path.open("wb") as output:
                    for block in response.iter_content(chunk_size=1024 * 1024):
                        if block:
                            output.write(block)
            entries.append({"bucket": bid, "path": name, "bytes": path.stat().st_size,
                            "sha256": digest(path, "sha256")})
    return entries, [b["id"] for b in buckets]


def oauth_access_token(s: requests.Session) -> str:
    r = s.post("https://oauth2.googleapis.com/token", data={
        "client_id": required("GDRIVE_CLIENT_ID"),
        "client_secret": required("GDRIVE_CLIENT_SECRET"),
        "refresh_token": required("GDRIVE_REFRESH_TOKEN"),
        "grant_type": "refresh_token",
    }, timeout=30)
    r.raise_for_status()
    return r.json()["access_token"]


def find_or_create_backup_folder(s: requests.Session, token: str) -> str:
    """Use a folder CREATED by this OAuth app; drive.file cannot access arbitrary old folders."""
    headers = {"Authorization": f"Bearer {token}"}
    query = ("mimeType = 'application/vnd.google-apps.folder' and trashed = false "
             "and appProperties has { key='constelmec_backup' and value='production' }")
    response = s.get("https://www.googleapis.com/drive/v3/files",
                     headers=headers, params={"q": query, "fields": "nextPageToken,files(id,name)",
                                              "pageSize": 100}, timeout=30)
    response.raise_for_status()
    folders = response.json().get("files", [])
    if len(folders) > 1:
        raise RuntimeError("Multiple backup folders detected; manual reconciliation required")
    if folders:
        return folders[0]["id"]
    response = s.post("https://www.googleapis.com/drive/v3/files",
                      headers={**headers, "Content-Type": "application/json"},
                      params={"fields": "id,name"},
                      json={"name": "CONSTELMEC_BACKUPS_AUTOMATICOS",
                            "mimeType": "application/vnd.google-apps.folder",
                            "appProperties": {"constelmec_backup": "production"}},
                      timeout=30)
    response.raise_for_status()
    folder_id = response.json()["id"]
    print(f"Created app-managed Drive folder: {folder_id}. "
          "Move it manually into CONSTELMEC_DATA/07_BACKUPS_SUPABASE if desired.")
    return folder_id


def upload_drive(s: requests.Session, path: Path, name: str) -> str:
    token = oauth_access_token(s)
    folder_id = find_or_create_backup_folder(s, token)
    headers = {"Authorization": f"Bearer {token}"}
    size = path.stat().st_size
    init = s.post("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,name,size,md5Checksum",
                  headers={**headers, "Content-Type": "application/json; charset=UTF-8",
                           "X-Upload-Content-Type": "application/zip",
                           "X-Upload-Content-Length": str(size)},
                  json={"name": name, "parents": [folder_id], "mimeType": "application/zip"},
                  timeout=60)
    init.raise_for_status()
    location = init.headers.get("Location")
    if not location or not location.startswith("https://"):
        raise RuntimeError("Drive did not return secure upload URL")
    metadata = None
    with path.open("rb") as source:
        start = 0
        while start < size:
            data = source.read(CHUNK_SIZE)
            end = start + len(data) - 1
            r = s.put(location, headers={"Content-Length": str(len(data)),
                                         "Content-Range": f"bytes {start}-{end}/{size}"},
                      data=data, timeout=(30, 300))
            if r.status_code == 308:
                if r.headers.get("Range") != f"bytes=0-{end}":
                    raise RuntimeError("Drive upload offset mismatch")
            elif r.status_code in (200, 201) and end == size - 1:
                metadata = r.json()
            else:
                r.raise_for_status()
                raise RuntimeError("Unexpected Drive upload response")
            start = end + 1
    if not metadata or not metadata.get("id"):
        raise RuntimeError("Drive upload did not complete")
    r = s.get(f"https://www.googleapis.com/drive/v3/files/{quote(metadata['id'], safe='')}",
              headers=headers, params={"fields": "id,size,md5Checksum",
                                       "supportsAllDrives": "true"}, timeout=30)
    r.raise_for_status()
    remote = r.json()
    if int(remote.get("size", -1)) != size or remote.get("md5Checksum") != digest(path, "md5"):
        raise RuntimeError("Drive verification FAILED: size or MD5 mismatch")
    return remote["id"]


def create_archive(directory: Path, password: str, manifest: dict, dest: Path):
    files = sorted(p for p in directory.rglob("*") if p.is_file())
    if not files:
        raise RuntimeError("No backup files to archive")
    manifest["files"] = [{"path": p.relative_to(directory).as_posix(),
                          "bytes": p.stat().st_size, "sha256": digest(p, "sha256")}
                         for p in files]
    manifest_bytes = json.dumps(manifest, indent=2, ensure_ascii=False).encode("utf-8")
    with pyzipper.AESZipFile(dest, "w", compression=pyzipper.ZIP_DEFLATED,
                             encryption=pyzipper.WZ_AES, compresslevel=6) as archive:
        archive.setpassword(password.encode("utf-8"))
        archive.setencryption(pyzipper.WZ_AES, nbits=256)
        archive.writestr("manifest.json", manifest_bytes)
        for path in files:
            archive.write(path, path.relative_to(directory).as_posix())
    with pyzipper.AESZipFile(dest) as archive:
        archive.setpassword(password.encode("utf-8"))
        if archive.testzip() is not None:
            raise RuntimeError("Encrypted archive failed integrity test")
        decoded = json.loads(archive.read("manifest.json"))
        if len(decoded["files"]) != len(files):
            raise RuntimeError("Archive manifest mismatch")
    return len(files)


def main():
    base = required("SUPABASE_URL").rstrip("/")
    if base != f"https://{PROJECT_REF}.supabase.co":
        raise RuntimeError("Safety guard: wrong Supabase project")
    key = required("SUPABASE_SERVICE_ROLE_KEY")
    password = required("BACKUP_ENCRYPTION_PASSWORD")
    if len(password) < 24:
        raise RuntimeError("BACKUP_ENCRYPTION_PASSWORD must have 24+ characters")
    dump_dir = Path(required("DB_DUMP_DIR"))
    db_files = [dump_dir / n for n in ("roles.sql", "schema.sql", "data.sql")]
    for file in db_files:
        if not file.is_file() or file.stat().st_size == 0:
            raise RuntimeError(f"Missing/empty database dump: {file.name}")
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    with tempfile.TemporaryDirectory(prefix="constelmec-backup-") as tmp:
        root = Path(tmp)
        work = root / "payload"
        db_dir = work / "database"
        db_dir.mkdir(parents=True)
        for file in db_files:
            (db_dir / file.name).write_bytes(file.read_bytes())
        s = session()
        objects, buckets = download_storage(s, base, key, work)
        manifest = {"created_at_utc": timestamp, "project_ref": PROJECT_REF,
                    "format": "supabase-cli-v2-sql-and-storage-aes256-zip",
                    "bucket_ids": buckets, "storage_object_count": len(objects),
                    "storage_objects": objects}
        archive = root / f"constelmec-prod-{timestamp}.zip"
        count = create_archive(work, password, manifest, archive)
        remote_id = upload_drive(s, archive, archive.name)
        print(f"PASS backup: {count} files; {len(objects)} Storage objects; "
              f"encrypted={archive.stat().st_size} bytes; Drive file ID={remote_id}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL backup: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
