import unittest

from validate_managed_schema import TRIGGER, expected_objects, validate


class ManagedSchemaTests(unittest.TestCase):
    def setUp(self):
        self.objects = list(expected_objects())
        self.definitions = [item[2] for item in self.objects]
        self.functions = []
        for kind, _, _, function in self.objects:
            args = "" if kind == "TRIGGER" else '"p_path" "text"'
            self.functions.append(f'CREATE FUNCTION "app_private"."{function}"({args}) RETURNS boolean')

    def test_complete_export_passes(self):
        validate("\n".join(self.definitions), "\n".join(self.functions))

    def test_every_required_object_is_checked(self):
        for index, (_, name, _, _) in enumerate(self.objects):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, name):
                validate("\n".join(self.definitions[:index] + self.definitions[index + 1:]),
                         "\n".join(self.functions))

    def test_no_storage_policies_fails(self):
        with self.assertRaisesRegex(ValueError, "maintenance_read_confirmed"):
            validate(self.definitions[-1], "\n".join(self.functions))

    def test_modified_incomplete_and_duplicate_definitions_fail(self):
        original = self.definitions[0]
        for variant in (original.replace("TO authenticated", "TO PUBLIC"),
                        original.removesuffix(";"), original + "\n" + original):
            with self.subTest(variant=variant), self.assertRaisesRegex(ValueError, "maintenance_read_confirmed"):
                validate("\n".join([variant, *self.definitions[1:]]), "\n".join(self.functions))

    def test_missing_dependency_and_disabled_trigger_fail(self):
        with self.assertRaisesRegex(ValueError, TRIGGER):
            validate("\n".join(self.definitions), "\n".join(self.functions[:-1]))
        with self.assertRaisesRegex(ValueError, "unexpected enabled state"):
            validate("\n".join([*self.definitions, f"ALTER TABLE auth.users DISABLE TRIGGER {TRIGGER};"]),
                     "\n".join(self.functions))
