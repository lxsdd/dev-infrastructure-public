"""Offline mutation regressions for shared publication guard; no network or credentials."""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "shared" / "ci" / "publication_guard.py"
spec = importlib.util.spec_from_file_location("shared_publication_guard", SOURCE)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

BASE = """name: Example
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  core:
    runs-on: ubuntu-latest
    steps:
      - name: Upload DLL
        if: false # source only
        uses: actions/upload-artifact@v7
        with:
          path: build/*.dll
  release:
    if: false # owner approval pending
    runs-on: ubuntu-latest
    steps:
      - name: Publish
        run: gh release create v1
"""
EXPECTED = {"build.yml": 1}
STEPS = {"build.yml": ["Upload DLL"]}
JOBS = {"build.yml": ["release"]}


class PublicationGuardTests(unittest.TestCase):
    def audit(self, source=BASE, **kwargs):
        opts = dict(expected_uploads=EXPECTED,
                    required_disabled_jobs=JOBS,
                    required_disabled_steps=STEPS,
                    allowed_workflows=["build.yml"])
        opts.update(kwargs)
        return module.scan_workflows({"build.yml": source}, **opts)

    def test_synthetic_baseline(self):
        self.assertEqual([], self.audit())

    def test_enabled_upload_rejected(self):
        self.assertTrue(self.audit(BASE.replace("if: false # source only",
                                                 "if: true")))

    def test_named_step_gate_must_not_borrow_neighbor_gate(self):
        bad = BASE.replace(
            "      - name: Upload DLL\n        if: false # source only",
            "      - name: Earlier\n        if: false\n        run: echo no-op\n"
            "      - name: Upload DLL")
        self.assertTrue(self.audit(bad))

    def test_direct_uses_step_literal_false_allowed(self):
        src = """jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v7
        if: false
"""
        self.assertEqual([], module.scan_workflows(
            {"a.yml": src}, {"a.yml": 1}))

    def test_direct_uses_step_enabled_rejected(self):
        src = """jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v7
"""
        self.assertTrue(module.scan_workflows({"a.yml": src}, {"a.yml": 1}))

    def test_job_level_gate_applies_to_its_upload_only(self):
        src = """jobs:
  disabled:
    if: false
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v7
  enabled:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v7
"""
        errors = module.scan_workflows({"a.yml": src}, {"a.yml": 2})
        self.assertEqual(1, len(errors), errors)

    def test_release_publication_requires_gate(self):
        self.assertTrue(self.audit(BASE.replace("if: false # owner approval pending",
                                                 "if: true")))
        self.assertTrue(self.audit(BASE.replace("        run: gh release create v1",
                                                 "        uses: softprops/action-gh-release@v2").replace(
                                                     "if: false # owner approval pending", "if: true")))

    def test_new_upload_workflow_rejected(self):
        data = {"build.yml": BASE, "new.yml":
                "jobs:\n  b:\n    steps:\n      - uses: actions/upload-artifact@v7\n"}
        self.assertTrue(module.scan_workflows(data, EXPECTED, JOBS, STEPS))

    def test_missing_required_gate_rejected(self):
        self.assertTrue(self.audit(BASE.replace("  release:\n    if: false", 
                                                 "  release:\n    if: true")))
        self.assertTrue(self.audit(BASE.replace("      - name: Upload DLL",
                                                 "      - name: Package")))

    def test_different_upload_action_count_rejected(self):
        self.assertTrue(module.scan_workflows({"build.yml": BASE}, {"build.yml": 2}))

    def test_allowlist_rejects_extra_files_even_without_uploads(self):
        self.assertTrue(module.scan_workflows(
            {"build.yml": BASE, "extra.yml": "jobs: {}"},
            EXPECTED, JOBS, STEPS, allowed_workflows=["build.yml"]))

    def test_dynamic_action_rejected(self):
        self.assertTrue(self.audit(BASE.replace("actions/upload-artifact@v7",
                                                 "${{ inputs.action_name }}")))

    def test_quoted_upload_cannot_bypass_expected_count_or_enabled_gate(self):
        for quote in ("'", '"'):
            with self.subTest(quote=quote):
                unsafe_step = (
                    "      - uses: " + quote +
                    "actions/upload-artifact@v7" + quote + "\n"
                )
                source = BASE.replace("  release:\n", unsafe_step + "  release:\n", 1)
                self.assertTrue(self.audit(source))

    def test_quoted_release_action_requires_gate(self):
        for action in ("softprops/action-gh-release@v2",
                       "actions/create-release@v1"):
            for quote in ("'", '"'):
                with self.subTest(action=action, quote=quote):
                    source = (
                        BASE + "  accidental:\n"
                        "    runs-on: ubuntu-latest\n"
                        "    steps:\n"
                        "      - uses: " + quote + action + quote + "\n"
                    )
                    self.assertTrue(self.audit(source))

    def test_yaml_action_alias_or_anchor_rejected(self):
        for value in ("*publication_action",
                      "&publication_action actions/upload-artifact@v7"):
            with self.subTest(value=value):
                source = BASE.replace(
                    "  release:\n",
                    "      - uses: " + value + "\n  release:\n", 1)
                self.assertTrue(self.audit(source))

    def test_quoted_upload_remains_valid_when_explicitly_disabled(self):
        for quote in ("'", '"'):
            with self.subTest(quote=quote):
                source = BASE.replace(
                    "uses: actions/upload-artifact@v7",
                    "uses: " + quote + "actions/upload-artifact@v7" + quote, 1)
                self.assertEqual([], self.audit(source))

    def test_quoted_action_comment_not_counted(self):
        source = BASE + "# - uses: 'actions/upload-artifact@v7'\n"
        self.assertEqual([], self.audit(source))

    def test_comments_not_counted(self):
        src = BASE + "\n# - uses: actions/upload-artifact@v7\n"
        self.assertEqual([], self.audit(src))

    def test_stale_or_unknown_policy_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github" / "workflows").mkdir(parents=True)
            (root / ".github" / "workflows" / "build.yml").write_text(BASE)
            self.assertTrue(module.audit_repository(root, {"version": 2}))
            self.assertEqual([], module.audit_repository(
                root, {"version": 1,
                       "expected_artifact_actions": EXPECTED,
                       "required_disabled_jobs": JOBS,
                       "required_disabled_steps": STEPS,
                       "allowed_workflows": ["build.yml"]}))


if __name__ == "__main__":
    unittest.main()
