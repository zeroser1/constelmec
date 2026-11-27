#!/usr/bin/env python3
"""One-time Google OAuth authorization for CONSTELMEC Backup.

Run on your own computer. Never paste the output in a chat or commit it.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from google_auth_oauthlib.flow import InstalledAppFlow

SCOPE = "https://www.googleapis.com/auth/drive.file"


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python scripts/authorize_drive.py path/to/client_secret.json")
        sys.exit(2)
    path = Path(sys.argv[1]).expanduser()
    if not path.is_file():
        sys.exit("Client JSON file not found.")
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    if "installed" not in data:
        sys.exit("Expected OAuth Desktop client JSON ('installed').")
    flow = InstalledAppFlow.from_client_config(data, scopes=[SCOPE])
    credentials = flow.run_local_server(
        host="localhost",
        port=0,
        open_browser=True,
        access_type="offline",
        prompt="consent",
        authorization_prompt_message="Open this URL in your browser: {url}",
        success_message="CONSTELMEC Backup authorized. You can close this tab.",
    )
    if not credentials.refresh_token:
        sys.exit("No refresh token received. Revoke app access and try again.")
    print("\nAuthorization complete. Copy these values directly into GitHub Actions secrets.")
    print("NEVER share them in chats or save them in the repository.\n")
    print("GDRIVE_CLIENT_ID =", data["installed"]["client_id"])
    print("GDRIVE_CLIENT_SECRET =", data["installed"]["client_secret"])
    print("GDRIVE_REFRESH_TOKEN =", credentials.refresh_token)
    print("\nScope: " + SCOPE)


if __name__ == "__main__":
    main()
