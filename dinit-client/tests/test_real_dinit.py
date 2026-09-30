"""Integration tests that drive a real dinit.

Skipped unless the environment names a dinit and two dinix instances to run it
against. The check's derivation attributes become this environment:

- ``DINIT_CLIENT_TEST_DINIT`` — an unbaked dinit binary, so the test chooses
  the service directory rather than a wrapper.
- ``DINIT_CLIENT_TEST_INSTANCE_A`` / ``_B`` — two configDir store paths that
  differ in one line of the hello service. A symlink under the test's temp
  directory points at one of them, and reload reads through the swap.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass
from pathlib import Path

import anyio
import pytest
from anyio import Path as AsyncPath
from anyio.streams.memory import MemoryObjectReceiveStream

from dinit_client import DinitClient
from dinit_client import protocol as p

_DINIT = os.environ.get("DINIT_CLIENT_TEST_DINIT")
_INSTANCE_A = os.environ.get("DINIT_CLIENT_TEST_INSTANCE_A")
_INSTANCE_B = os.environ.get("DINIT_CLIENT_TEST_INSTANCE_B")

pytestmark = pytest.mark.skipif(
    not (_DINIT and _INSTANCE_A and _INSTANCE_B),
    reason="needs DINIT_CLIENT_TEST_DINIT and DINIT_CLIENT_TEST_INSTANCE_A/_B",
)


@dataclass
class UnderTest:
    client: DinitClient
    services_dir: AsyncPath

    async def use_instance(self, config_dir: str) -> None:
        """Point the service-directory symlink at another instance, atomically."""
        link = self.services_dir.parent
        temporary = link.with_name(link.name + ".new")
        with suppress(FileNotFoundError):
            await temporary.unlink()
        await temporary.symlink_to(config_dir)
        await temporary.rename(link)


@asynccontextmanager
async def running_dinit(tmp_path: Path) -> AsyncIterator[UnderTest]:
    link = AsyncPath(tmp_path) / "instance"
    await link.symlink_to(_INSTANCE_A)
    services = link / "services"
    socket = AsyncPath(tmp_path) / "control"
    process = await anyio.open_process(
        [_DINIT, "--user", "--socket-path", str(socket), "--services-dir", str(services)],
        env={**os.environ, "HOME": str(tmp_path)},
    )
    try:
        with anyio.move_on_after(10) as scope:
            while not await socket.exists():
                await anyio.sleep(0.05)
        if scope.cancelled_caught:
            raise RuntimeError("dinit did not create its control socket within 10s")
        async with DinitClient.connect(str(socket)) as client:
            yield UnderTest(client=client, services_dir=services)
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
    async with running_dinit(tmp_path) as under:
        # Nothing references these from boot, so dinit has not loaded them yet.
        # They appear only after LOADSERVICE, which is the whole point.
        await under.client.load("hello")
        await under.client.load("world")
        services = await under.client.list_services()
    assert {"boot", "hello", "world"} <= set(services)
    assert services["boot"].state is p.ServiceState.STARTED
    assert services["world"].state is p.ServiceState.STOPPED


async def test_query_load_mech_names_the_instance_dir(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as under:
        mech = await under.client.query_load_mech()
    assert str(under.services_dir) in mech.dirs


async def test_start_reaches_started_with_a_pid(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as under:
        await under.client.start("hello")
        await _await_state(under.client, "hello", p.ServiceState.STARTED)
        status = await under.client.status("hello")
    assert status.pid is not None


async def test_start_emits_started_event(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as under:
        handle = (await under.client.load("hello")).handle
        events = under.client.subscribe()
        await under.client.start("hello")
        event = await _await_event(events, handle, p.ServiceEvent.STARTED)
    assert event.status.state is p.ServiceState.STARTED


async def test_catlog_returns_buffered_output(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as under:
        await under.client.start("hello")
        log = await _await_log(under.client, "hello", b"hello-from-hello")
    assert b"hello-from-hello" in log


async def test_reload_picks_up_a_swapped_description(tmp_path: Path) -> None:
    async with running_dinit(tmp_path) as under:
        client = under.client
        await client.start("hello")
        await _await_log(client, "hello", b"hello-from-hello")

        await under.use_instance(_INSTANCE_B)
        await client.reload("hello")
        await client.restart("hello")

        log = await _await_log(client, "hello", b"hello-from-swapped")
    assert b"hello-from-swapped" in log
