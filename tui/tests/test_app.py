from __future__ import annotations

import os
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from pathlib import Path

import anyio
from anyio.streams.memory import MemoryObjectReceiveStream, MemoryObjectSendStream
from dinit_client import protocol as p
from textual.pilot import Pilot
from textual.widgets import DataTable

from dinix_tui import DinixApp


def _status(state: p.ServiceState, pid: int | None = None) -> p.ServiceStatus:
    return p.ServiceStatus(
        state=state,
        target_state=state,
        flags=0,
        stop_reason=p.StoppedReason.NORMAL,
        pid=pid,
    )


class FakeClient:
    """The slice of DinitClient the app uses, with a hand-fed event stream."""

    def __init__(self) -> None:
        self.protocol_version = 7
        self.states: dict[str, p.ServiceState] = {
            "hello": p.ServiceState.STOPPED,
            "world": p.ServiceState.STARTED,
        }
        self.handles: dict[str, int] = {}
        self.commands: list[tuple[str, str]] = []
        self._events_send, self._events = anyio.create_memory_object_stream(8)

    def subscribe(self) -> MemoryObjectReceiveStream[p.Event]:
        return self._events

    def events_send(self) -> MemoryObjectSendStream[p.Event]:
        return self._events_send

    async def list_services(self) -> dict[str, p.ServiceStatus]:
        return {name: _status(state) for name, state in self.states.items()}

    async def query_load_mech(self) -> p.LoaderMech:
        return p.LoaderMech(loader_type=p.LoaderType.DIRLOAD, cwd="/", dirs=())

    async def load(self, name: str) -> p.ServiceRecord:
        self.states.setdefault(name, p.ServiceState.STOPPED)
        handle = self.handles.setdefault(name, len(self.handles) + 1)
        state = self.states[name]
        return p.ServiceRecord(state=state, handle=handle, target_state=state)

    async def start(self, name: str, *, pin: bool = False) -> None:
        self.commands.append(("start", name))
        self.states[name] = p.ServiceState.STARTED

    async def stop(self, name: str, *, pin: bool = False, force: bool = False) -> None:
        self.commands.append(("stop", name))
        self.states[name] = p.ServiceState.STOPPED

    async def restart(self, name: str) -> None:
        self.commands.append(("restart", name))

    async def reload(self, name: str) -> None:
        self.commands.append(("reload", name))

    async def catlog(self, name: str, *, clear: bool = False) -> bytes:
        return b"a log line\n"


def app_with(client: FakeClient, **kwargs: object) -> DinixApp:
    @asynccontextmanager
    async def connector(_socket_path: str | None) -> AsyncIterator[FakeClient]:
        yield client

    return DinixApp(connector=connector, **kwargs)


async def _until(pilot: Pilot[None], predicate: Callable[[], bool], timeout: float = 5.0) -> None:
    with anyio.fail_after(timeout):
        while not predicate():
            await anyio.sleep(0.01)
            await pilot.pause()


def _build(tmp_path: Path, *names: str) -> Path:
    build = tmp_path / "build"
    (build / "services").mkdir(parents=True)
    for name in names:
        (build / "services" / name).write_text("type = internal\n")
    return build


async def test_rows_are_listed() -> None:
    app = app_with(FakeClient())
    async with app.run_test() as pilot:
        await pilot.pause()
        table = app.query_one(DataTable)
        assert table.row_count == 2
        assert table.get_cell("world", "state") == "started"
        # Selection comes from the cursor, so it exists before any key press.
        assert app._current_service() == "hello"


async def test_event_updates_a_row() -> None:
    client = FakeClient()
    app = app_with(client)
    async with app.run_test() as pilot:
        await pilot.pause()
        handle = client.handles["hello"]
        await client.events_send().send(
            p.ServiceEventInfo(
                handle=handle,
                event=p.ServiceEvent.STARTED,
                status=_status(p.ServiceState.STARTED, pid=99),
            )
        )
        await pilot.pause()
        table = app.query_one(DataTable)
        assert table.get_cell("hello", "state") == "started"
        assert table.get_cell("hello", "pid") == "99"


async def test_start_uses_the_highlighted_row() -> None:
    client = FakeClient()
    app = app_with(client)
    async with app.run_test() as pilot:
        await pilot.pause()
        table = app.query_one(DataTable)
        table.move_cursor(row=table.get_row_index("hello"))
        await pilot.pause()
        await pilot.press("s")
        await pilot.pause()
    assert ("start", "hello") in client.commands


async def test_nix_reload_repoints_and_reloads_every_service(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    build = _build(tmp_path, "hello", "extra")
    client = FakeClient()

    async def rebuild() -> str:
        return str(build)

    app = app_with(client, runtime_dir=str(runtime), rebuilder=rebuild)
    async with app.run_test() as pilot:
        await _until(pilot, lambda: app.query_one(DataTable).row_count == 2)
        app.action_nix_reload()

        def reloaded() -> set[str]:
            return {name for action, name in client.commands if action == "reload"}

        await _until(pilot, lambda: {"hello", "world", "extra"} <= reloaded())
        table = app.query_one(DataTable)
        assert table.get_cell("extra", "state") == "stopped"
    assert os.readlink(runtime / "current") == str(build / "services")


async def test_nix_reload_runs_the_configured_command(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    build = _build(tmp_path, "hello")
    client = FakeClient()
    app = app_with(
        client,
        runtime_dir=str(runtime),
        nix_command=f"printf '%s\\n' {build}",
    )
    async with app.run_test() as pilot:
        await _until(pilot, lambda: app.query_one(DataTable).row_count == 2)
        app.action_nix_reload()
        await _until(pilot, lambda: (runtime / "current").exists())
    assert os.readlink(runtime / "current") == str(build / "services")
    assert ("reload", "hello") in client.commands


async def test_nix_reload_without_a_command_queues_nothing(tmp_path: Path) -> None:
    app = app_with(FakeClient(), runtime_dir=str(tmp_path / "runtime"))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.action_nix_reload()
        await pilot.pause()
        assert app._commands.statistics().current_buffer_used == 0
