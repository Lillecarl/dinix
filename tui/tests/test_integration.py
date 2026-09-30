"""Integration tests that drive the TUI against a real dinit.

Skipped unless the environment names a dinit and two dinix instances. The
check's derivation attributes become this environment:

- ``DINIX_TUI_TEST_DINIT`` — an unbaked dinit binary, so the test chooses the
  service directory rather than a wrapper.
- ``DINIX_TUI_TEST_INSTANCE_A`` / ``_B`` — two configDir store paths that
  differ in one line of the hello service. A nix reload points the runtime
  pointer at B, and a restart makes the new line visible in the log.

These exercise the whole stack: the Textual pilot, the app, the control client
and dinit. The unit tests use a fake client; here the socket is real.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from pathlib import Path

import anyio
import pytest
from anyio import Path as AsyncPath
from textual.pilot import Pilot
from textual.widgets import DataTable, RichLog

from dinix_tui import DinixApp

_DINIT = os.environ.get("DINIX_TUI_TEST_DINIT")
_INSTANCE_A = os.environ.get("DINIX_TUI_TEST_INSTANCE_A")
_INSTANCE_B = os.environ.get("DINIX_TUI_TEST_INSTANCE_B")

pytestmark = pytest.mark.skipif(
    not (_DINIT and _INSTANCE_A and _INSTANCE_B),
    reason="needs DINIX_TUI_TEST_DINIT and DINIX_TUI_TEST_INSTANCE_A/_B",
)


@asynccontextmanager
async def running_dinit(runtime: Path) -> AsyncIterator[str]:
    """A dinit whose service directories are the runtime's and instance A's."""
    (runtime / "services").mkdir(parents=True, exist_ok=True)
    socket = runtime / "control"
    process = await anyio.open_process(
        [
            _DINIT,
            "--user",
            "--socket-path",
            str(socket),
            # The wrapper's order: the writable dir, then the pointer the app
            # repoints at a build, then the store's own services.
            "--services-dir",
            str(runtime / "services"),
            "--services-dir",
            str(runtime / "current"),
            "--services-dir",
            f"{_INSTANCE_A}/services",
        ],
        env={**os.environ, "HOME": str(runtime)},
    )
    try:
        with anyio.move_on_after(10) as scope:
            while not await AsyncPath(socket).exists():
                await anyio.sleep(0.05)
        if scope.cancelled_caught:
            raise RuntimeError("dinit did not create its control socket within 10s")
        yield str(socket)
    finally:
        process.terminate()
        with anyio.move_on_after(5):
            await process.wait()


async def _until(
    pilot: Pilot[None],
    predicate: Callable[[], bool],
    app: DinixApp,
    timeout: float = 10.0,
) -> None:
    with anyio.move_on_after(timeout) as scope:
        while not predicate():
            await anyio.sleep(0.02)
            await pilot.pause()
    if scope.cancelled_caught:
        raise AssertionError(f"condition not met within {timeout}s; log so far:\n{_log_text(app)}")


def _state(app: DinixApp, name: str) -> str:
    if name not in app._known:
        return ""
    return str(app.query_one(DataTable).get_cell(name, "state"))


def _pid(app: DinixApp, name: str) -> str:
    if name not in app._known:
        return ""
    return str(app.query_one(DataTable).get_cell(name, "pid"))


def _log_text(app: DinixApp) -> str:
    return "\n".join(strip.text for strip in app.query_one(RichLog).lines)


async def test_lists_the_instance_services(tmp_path: Path) -> None:
    async with running_dinit(tmp_path / "runtime") as socket:
        app = DinixApp(socket_path=socket)
        async with app.run_test() as pilot:
            await _until(pilot, lambda: _state(app, "world") == "stopped", app)
            assert _state(app, "boot") == "started"


async def test_start_show_log_then_nix_reload_and_restart(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    async with running_dinit(runtime) as socket:
        app = DinixApp(socket_path=socket, nix_command=f"echo {_INSTANCE_B}")
        async with app.run_test() as pilot:
            await _until(pilot, lambda: _state(app, "hello") == "stopped", app)
            table = app.query_one(DataTable)
            table.move_cursor(row=table.get_row_index("hello"))
            await pilot.pause()
            await pilot.press("s")
            await _until(pilot, lambda: _state(app, "hello") == "started", app)
            assert _pid(app, "hello")

            await pilot.press("l")
            await _until(pilot, lambda: "hello-from-hello" in _log_text(app), app)

            await pilot.press("n")
            await _until(pilot, lambda: (runtime / "current").exists(), app)

            await pilot.press("r")
            await _until(pilot, lambda: _state(app, "hello") == "started", app)
            await pilot.press("l")
            await _until(pilot, lambda: "hello-from-swapped" in _log_text(app), app)

    assert os.readlink(runtime / "current") == f"{_INSTANCE_B}/services"


async def test_nix_reload_loads_a_service_the_rebuild_added(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    build = tmp_path / "build"
    (build / "services").mkdir(parents=True)
    for entry in Path(f"{_INSTANCE_A}/services").iterdir():
        (build / "services" / entry.name).write_bytes(entry.read_bytes())
    (build / "services" / "extra").write_text("type = internal\n")

    async with running_dinit(runtime) as socket:
        app = DinixApp(socket_path=socket, nix_command=f"echo {build}")
        async with app.run_test() as pilot:
            await _until(pilot, lambda: _state(app, "world") == "stopped", app)
            assert app.query_one(DataTable).row_count == 3

            await pilot.press("n")
            await _until(pilot, lambda: _state(app, "extra") == "stopped", app)
            assert app.query_one(DataTable).row_count == 4
