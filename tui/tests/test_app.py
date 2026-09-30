from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import anyio
from anyio.streams.memory import MemoryObjectReceiveStream, MemoryObjectSendStream
from dinit_client import protocol as p
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

    async def load(self, name: str) -> p.ServiceRecord:
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


@asynccontextmanager
async def fake_connector(_socket_path: str | None) -> AsyncIterator[FakeClient]:
    yield FakeClient()


def app_with(client: FakeClient) -> DinixApp:
    @asynccontextmanager
    async def connector(_socket_path: str | None) -> AsyncIterator[FakeClient]:
        yield client

    return DinixApp(connector=connector)


async def test_rows_are_listed() -> None:
    app = app_with(FakeClient())
    async with app.run_test() as pilot:
        await pilot.pause()
        table = app.query_one(DataTable)
        assert table.row_count == 2
        assert table.get_cell("world", "state") == "started"


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


async def test_start_action_dispatches_to_the_client() -> None:
    client = FakeClient()
    app = app_with(client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "hello"
        app.action_start()
        await pilot.pause()
    assert ("start", "hello") in client.commands
