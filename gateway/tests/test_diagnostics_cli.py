"""v0.26.4: ``portico-gateway diagnostics on | off | status`` — the one switch for the diagnostics suite.

Driven through ``main`` in-process on a throwaway state directory. Everything lives under
``<state>/diagnostics/``; nothing is ever written at the state directory's root.
"""

from __future__ import annotations

import json

import pytest

from portico_gateway.__main__ import main


def test_on_creates_switch_readme_and_modes(tmp_path):
    home = tmp_path / "home"
    assert main(["diagnostics", "on", "--state", str(home)]) == 0
    d = home / "diagnostics"
    assert (d / "on").exists() and (d / "README").read_text().startswith("Diagnostics for the deployment's Daedalus")
    assert oct(d.stat().st_mode & 0o777) == "0o700" and oct((d / "on").stat().st_mode & 0o777) == "0o600"
    assert oct((d / "README").stat().st_mode & 0o777) == "0o600"
    assert main(["diagnostics", "on", "--state", str(home)]) == 0  # idempotent
    assert oct((d / "README").stat().st_mode & 0o777) == "0o600"


def test_status_reports_on_off_and_files(tmp_path, capsys):
    home = tmp_path / "home"
    assert main(["diagnostics", "status", "--state", str(home)]) == 3
    main(["diagnostics", "on", "--state", str(home)])
    (home / "diagnostics" / "recordings").mkdir()
    (home / "diagnostics" / "recordings" / "3-x.jsonl").write_text("{}\n")
    capsys.readouterr()
    assert main(["diagnostics", "status", "--state", str(home), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["on"] is True and {"name": "recordings/3-x.jsonl", "bytes": 3} in out["files"]


def test_off_deletes_everything_and_nothing_at_root(tmp_path):
    home = tmp_path / "home"
    main(["diagnostics", "on", "--state", str(home)])
    (home / "diagnostics" / "trace.log").write_text("x")
    assert main(["diagnostics", "off", "--state", str(home)]) == 0
    assert not (home / "diagnostics").exists()
    assert sorted(p.name for p in home.iterdir()) == []  # the switch never touched the root
    assert main(["diagnostics", "off", "--state", str(home)]) == 0  # absent is fine


def test_help_carries_the_wording(capsys):
    with pytest.raises(SystemExit):
        main(["diagnostics", "--help"])
    assert "Off unless turned on here" in capsys.readouterr().out


def test_off_unlinks_a_symlinked_diagnostics_and_leaves_the_target(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    target = tmp_path / "elsewhere"
    target.mkdir()
    (target / "keep.txt").write_text("x")
    (home / "diagnostics").symlink_to(target)
    assert main(["diagnostics", "off", "--state", str(home)]) == 0
    assert not (home / "diagnostics").exists() and not (home / "diagnostics").is_symlink()
    assert (target / "keep.txt").read_text() == "x"


def test_off_that_cannot_delete_exits_1_and_names_what_remains(tmp_path, capsys):
    home = tmp_path / "home"
    main(["diagnostics", "on", "--state", str(home)])
    stuck = home / "diagnostics" / "recordings"
    stuck.mkdir()
    (stuck / "3-x.jsonl").write_text("{}\n")
    stuck.chmod(0o500)
    capsys.readouterr()
    try:
        assert main(["diagnostics", "off", "--state", str(home)]) == 1
        err = capsys.readouterr().err
        assert "recordings" in err and "3-x.jsonl" in err
    finally:
        stuck.chmod(0o700)


def test_off_removes_the_switch_before_the_folder(tmp_path, monkeypatch):
    """The app polls ``on``: gone first, it stops writing (no ``trace.log`` made again mid-delete).

    The delete reports through ``onexc`` (``onerror`` is deprecated in Python 3.12).
    """
    import shutil

    from portico_gateway import diagnostics

    home = tmp_path / "home"
    main(["diagnostics", "on", "--state", str(home)])
    (home / "diagnostics" / "trace.log").write_text("x")
    seen = {}
    real = shutil.rmtree

    def spy(path, *args, **kwargs):
        seen["on at rmtree"] = (home / "diagnostics" / "on").exists()
        seen["kwargs"] = sorted(kwargs)
        return real(path, *args, **kwargs)

    monkeypatch.setattr(diagnostics.shutil, "rmtree", spy)
    assert main(["diagnostics", "off", "--state", str(home)]) == 0
    assert seen == {"on at rmtree": False, "kwargs": ["onexc"]}
    assert not (home / "diagnostics").exists()
