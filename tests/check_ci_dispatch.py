"""Offline contract regression for shared CI dispatcher. Synthetic GitHub responses only."""
from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlparse, unquote

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/dispatch-pr-head-ci.yml"
PREFIX = "          "
HEAD = "a" * 40


def load_script() -> str:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = next(i for i, row in enumerate(lines) if "python3 - <<'PY'" in row)
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == PREFIX + "PY")
    script = "\n".join(
        line[len(PREFIX):] if line.startswith(PREFIX) else line
        for line in lines[start + 1:end]
    ) + "\n"
    compile(script, str(WORKFLOW), "exec")
    return script


class FakeResponse:
    def __init__(self, value):
        self.raw = b"" if value is None else json.dumps(value).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self.raw


def run_case(*, private=False, runs=0, pr_foreign=False, changed=False,
             workflow_files="build.yml", pr_numbers="7"):
    dispatched = []

    def fake_open(req, timeout):
        assert timeout == 20
        assert req.get_header("Authorization") == "Bearer synthetic-only"
        parsed = urlparse(req.full_url)
        path = unquote(parsed.path).split("/repos/lxsdd/synthetic/", 1)[1]
        if path == "":
            return FakeResponse({"private": private})
        if path == "actions/workflows/build.yml":
            return FakeResponse({"state": "active",
                                 "path": ".github/workflows/build.yml"})
        if path == "pulls/7":
            return FakeResponse({
                "state": "open",
                "base": {"ref": "main"},
                "head": {"ref": "feature/synthetic", "sha": HEAD,
                         "repo": {"full_name": "other/repository" if pr_foreign
                                  else "lxsdd/synthetic"}},
            })
        if path == "branches/feature/synthetic":
            return FakeResponse({"commit": {"sha": "b" * 40 if changed else HEAD}})
        if path.startswith("actions/workflows/build.yml/runs?"):
            return FakeResponse({"total_count": runs})
        if path == "actions/workflows/build.yml/dispatches":
            assert req.get_method() == "POST"
            assert json.loads(req.data.decode("utf-8")) == {
                "ref": "feature/synthetic"}
            dispatched.append(path)
            return FakeResponse(None)
        raise AssertionError("Unexpected API call: " + path)

    env = {
        "GITHUB_REPOSITORY": "lxsdd/synthetic",
        "GH_TOKEN": "synthetic-only",
        "PR_NUMBERS": pr_numbers,
        "WORKFLOW_FILES": workflow_files,
        "BASE_BRANCH": "main",
    }
    output = io.StringIO()
    error = None
    with patch.dict(os.environ, env), patch("urllib.request.urlopen", fake_open):
        with contextlib.redirect_stdout(output):
            try:
                exec(compile(load_script(), str(WORKFLOW), "exec"), {
                    "__name__": "__ci_dispatch_contract_test__"})
            except SystemExit as exc:
                error = exc
    return dispatched, str(output.getvalue()), error


def main():
    done, out, error = run_case()
    assert len(done) == 1 and "DISPATCH" in out and error is None

    done, out, error = run_case(runs=1)
    assert done == [] and "existing CI" in out and error is None

    done, out, error = run_case(private=True)
    assert done == [] and "private repository" in out and error is not None
    assert error.code == 0

    done, out, error = run_case(pr_foreign=True)
    assert done == [] and "foreign" in out and error is None

    done, out, error = run_case(changed=True)
    assert done == [] and "changed" in out and error is None

    for name in ("promote-release.yml", "private-personal-component.yml",
                 "../build.yml", "candidate.yml"):
        done, out, error = run_case(workflow_files=name)
        assert done == [] and error is not None and error.code != 0

    done, out, error = run_case(pr_numbers="7,7")
    assert done == [] and error is not None and error.code != 0
    print("PASS: shared public CI dispatcher synthetic safety and dedupe")


if __name__ == "__main__":
    main()
