"""Check the schema objects required to recover CONSTELMEC."""

import re
import sys
from pathlib import Path


TRIGGER = "link_guilliman_pilot_auth"


def expected_objects():
    for prefix, bucket, resource in (
        ("maintenance", "maintenance-evidence", "maintenance_photo"),
        ("observation", "observation-files", "observation_attachment"),
    ):
        for suffix, action, clause, operation in (
            ("read_confirmed", "SELECT", "USING", "read"),
            ("upload_reserved", "INSERT", "WITH CHECK", "upload"),
        ):
            name = f"{prefix}_{suffix}"
            function = f"can_{operation}_{resource}"
            definition = (
                f"CREATE POLICY {name} ON storage.objects AS PERMISSIVE FOR {action} "
                f"TO authenticated {clause} (((bucket_id = '{bucket}'::text) "
                f"AND app_private.{function}(name)));"
            )
            yield "POLICY", name, definition, function
    yield (
        "TRIGGER", TRIGGER,
        f"CREATE TRIGGER {TRIGGER} AFTER INSERT ON auth.users FOR EACH ROW "
        f"EXECUTE FUNCTION app_private.{TRIGGER}();",
        TRIGGER,
    )


def validate(managed_sql: str, schema_sql: str) -> None:
    for kind, name, definition, function in expected_objects():
        table = r"storage\.objects" if kind == "POLICY" else r"auth\.users"
        matches = re.findall(
            rf'^CREATE {kind} (?:"{name}"|{name})\s+[^\n]*\bON {table}\b[^\n]*$',
            managed_sql, re.MULTILINE,
        )
        if matches != [definition]:
            raise ValueError(f"Required {kind.lower()} {name} is missing, duplicated or changed")
        signature = r"\(\)" if kind == "TRIGGER" else r'\("p_path" "text"\)'
        if not re.search(
            rf'^CREATE (?:OR REPLACE )?FUNCTION "app_private"\."{function}"{signature} RETURNS ',
            schema_sql, re.MULTILINE,
        ):
            raise ValueError(f"Required function app_private.{function} is missing")
    if re.search(
        rf'^ALTER TABLE auth\.users (?:DISABLE|ENABLE (?:REPLICA|ALWAYS)) TRIGGER {TRIGGER};$',
        managed_sql, re.MULTILINE,
    ):
        raise ValueError(f"Required trigger {TRIGGER} has an unexpected enabled state")


if __name__ == "__main__":
    try:
        validate(*(Path(arg).read_text(encoding="utf-8") for arg in sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(f"Invalid managed schema export: {error}")
