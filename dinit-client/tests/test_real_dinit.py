"""Integration tests that drive a real dinit.

Skipped unless ``DINIT_CLIENT_TEST_DINIT`` names a dinit to run. The instance
under test is a dinix user wrapper, so its service directory is already baked
into the executable; ``DINIT_CLIENT_TEST_SERVICES_DIR`` names that directory
for assertions.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import anyio
import pytest
from anyio import Path as AsyncPath
from anyio.streams.memory import MemoryObjectReceiveStream

from dinit_client import DinitClient
from dinit_client import protocol as p

_DINIT = os.environ.get("DINIT_CLIENT_TEST_DINIT")
_SERVICES_DIR = os.environ.get("DINIT_CLIENT_TEST_SERVICES_DIR")

pytestmark = pytest.mark.skipif(
    not (_DINIT and _SERVICES_DIR),
    reason="set DINIT_CLIENT_TEST_DINIT and DINIT_CLIENT_TEST_SERVICES_DIR to run",
)


@asynccontextmanager
async def running_dinit(tmp_path: Path) -> AsyncIterator[DinitClient]:
    socket = AsyncPath(tmp_path) / "control"
    process = await anyio.open_process(
        [_DINIT, "--user", "--socket-path", str(socket)],
        env={**os.environ, "HOME": str(tmp_path)},
    )
    try:
        with anyio.move_on_after(10) as scope:
            while not await socket.exists():
                await anyio.sleep(0.05)
        if scope.cancelled_caught:
            raise RuntimeError("dinit did not create its control socket within 10s")
        async with DinitClient.connect(str(socket)) as client:
            yield client
    finally:
        process.terminate()
        with anyio.move_on_after(5):
            await process.wait()


async def _await_state(
    client: DinitClient, name: str, state: p.ServiceState, timeout: float = 10.0
) -> None:
    with anyio.fail_after(timeout):
        while (await client.status(name)).state is not state:
            await anyio.sleep(0.05)


async def _await_event(
    events: MemoryObjectReceiveStream[p.Event],
    handle: int,
    kind: p.ServiceEvent,
    timeout: float = 10.0,
) -> p.ServiceEventInfo:
    with anyio.fail_after(timeout):
        while True:
            event = await events.receive()
            if (
                isinstance(event, p.ServiceEventInfo)
                and event.handle == handle
                and event.event is kind
            ):
                return event


async def _await_log(client: DinitClient, name: str, marker: bytes, timeout: float = 10.0) -> bytes:
    with anyio.fail_after(timeout):
        while True:
            log = await client.catlog(name)
            if marker in log:
                return log
            await anyio.sleep(0.05)


async def test_load_then_list_reports_instance_services(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as client:
        # Nothing references these from boot, so dinit has not loaded them yet.
        # They appear only after LOADSERVICE, which is the whole point.
        await client.load("hello")
        await client.load("world")
        services = await client.list_services()
    assert {"boot", "hello", "world"} <= set(services)
    assert services["boot"].state is p.ServiceState.STARTED
    assert services["world"].state is p.ServiceState.STOPPED


async def test_query_load_mech_names_the_instance_dir(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as client:
        mech = await client.query_load_mech()
    assert _SERVICES_DIR in mech.dirs


async def test_start_reaches_started_with_a_pid(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as client:
        await client.start("hello")
        await _await_state(client, "hello", p.ServiceState.STARTED)
        status = await client.status("hello")
    assert status.pid is not None


async def test_start_emits_started_event(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as client:
        handle = (await client.load("hello")).handle
        events = client.subscribe()
        await client.start("hello")
        event = await _await_event(events, handle, p.ServiceEvent.STARTED)
    assert event.status.state is p.ServiceState.STARTED


async def test_catlog_returns_buffered_output(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as client:
        await client.start("hello")
        log = await _await_log(client, "hello", b"hello-from-hello")
    assert b"hello-from-hello" in log
