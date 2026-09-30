from __future__ import annotations

import struct
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import anyio
import pytest
from anyio.abc import SocketStream

from dinit_client import DinitClient, ServiceNotFound
from dinit_client import protocol as p


async def _recv_exactly(stream: SocketStream, count: int) -> bytes:
    parts: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = await stream.receive(remaining)
        if not chunk:
            raise anyio.EndOfStream
        parts.append(chunk)
        remaining -= len(chunk)
    return b"".join(parts)


async def _recv_length_prefixed(stream: SocketStream) -> bytes:
    (length,) = struct.unpack("=H", await _recv_exactly(stream, 2))
    return await _recv_exactly(stream, length)


def _status6(state: p.ServiceState, pid: int) -> bytes:
    buf = bytearray(p.STATUS6_SIZE)
    buf[0] = state
    buf[1] = state
    buf[2] = p.FLAG_HAS_PID
    struct.pack_into("@i", buf, 6, pid)
    return bytes(buf)


def _svcinfo5(name: bytes, state: p.ServiceState) -> bytes:
    return bytes([p.Reply.SVCINFO, len(name)]) + _status6(state, 0)[: p.STATUS5_SIZE] + name


async def _handle_connection(stream: SocketStream) -> None:
    async with stream:
        while True:
            try:
                command = (await _recv_exactly(stream, 1))[0]
            except (anyio.EndOfStream, anyio.BrokenResourceError):
                return

            if command == p.Command.QUERYVERSION:
                await stream.send(bytes([p.Reply.CPVERSION]) + struct.pack("=HH", 1, 7))
            elif command in (p.Command.FINDSERVICE, p.Command.LOADSERVICE):
                name = await _recv_length_prefixed(stream)
                if name == b"missing":
                    await stream.send(bytes([p.Reply.NOSERVICE]))
                else:
                    await stream.send(
                        bytes([p.Reply.SERVICERECORD, p.ServiceState.STARTED])
                        + struct.pack("=I", 5)
                        + bytes([p.ServiceState.STARTED])
                    )
            elif command == p.Command.LISTSERVICES5:
                await stream.send(_svcinfo5(b"alpha", p.ServiceState.STARTED))
                await stream.send(_svcinfo5(b"beta", p.ServiceState.STOPPED))
                await stream.send(bytes([p.Reply.LISTDONE]))
            elif command == p.Command.SERVICESTATUS6:
                await _recv_exactly(stream, 4)
                await stream.send(
                    bytes([p.Reply.SERVICESTATUS, 0]) + _status6(p.ServiceState.STARTED, 321)
                )
            elif command == p.Command.STARTSERVICE:
                await _recv_exactly(stream, 1)
                handle = await _recv_exactly(stream, 4)
                payload = (
                    handle
                    + bytes([p.ServiceEvent.STARTED])
                    + _status6(p.ServiceState.STARTED, 321)[: p.STATUS5_SIZE]
                )
                await stream.send(bytes([p.Info.SERVICEEVENT5, len(payload) + 2]) + payload)
                await stream.send(bytes([p.Reply.ACK]))
            elif command in (
                p.Command.RELOADSERVICE,
                p.Command.UNLOADSERVICE,
                p.Command.STOPSERVICE,
            ):
                await _recv_exactly(stream, 4)
                await stream.send(bytes([p.Reply.ACK]))
            elif command == p.Command.SETENV:
                await _recv_length_prefixed(stream)
                await stream.send(bytes([p.Reply.ACK]))
            elif command == p.Command.CATLOG:
                await _recv_exactly(stream, 5)
                data = b"hello log\n"
                await stream.send(
                    bytes([p.Reply.SERVICE_LOG, 0]) + struct.pack("=I", len(data)) + data
                )
            elif command == p.Command.GETALLENV:
                await _recv_exactly(stream, 1)
                block = b"HOME=/root\0"
                await stream.send(bytes([p.Reply.ALLENV]) + struct.pack("@L", len(block)) + block)
            elif command == p.Command.QUERY_LOAD_MECH:
                cwd = b"/work"
                dirs = [b"/store/services", b"/runtime/services"]
                body = (
                    struct.pack("=II", len(dirs), len(cwd))
                    + cwd
                    + b"".join(struct.pack("=I", len(d)) + d for d in dirs)
                )
                await stream.send(
                    bytes([p.Reply.LOADER_MECH, p.LoaderType.DIRLOAD])
                    + struct.pack("=I", 6 + len(body))
                    + body
                )
            else:
                await stream.send(bytes([p.Reply.BADREQ]))


@asynccontextmanager
async def running_daemon(path: Path) -> AsyncIterator[Path]:
    listener = await anyio.create_unix_listener(str(path))
    async with anyio.create_task_group() as task_group:
        task_group.start_soon(listener.serve, _handle_connection)
        try:
            yield path
        finally:
            task_group.cancel_scope.cancel()
    await listener.aclose()


@asynccontextmanager
async def connected_client(tmp_path: Path) -> AsyncIterator[DinitClient]:
    async with (
        running_daemon(tmp_path / "control"),
        DinitClient.connect(str(tmp_path / "control")) as client,
    ):
        yield client


async def test_connect_negotiates_protocol(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        assert client.protocol_version == 7


async def test_list_services(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        services = await client.list_services()
    assert set(services) == {"alpha", "beta"}
    assert services["alpha"].state is p.ServiceState.STARTED
    assert services["beta"].state is p.ServiceState.STOPPED


async def test_find_returns_record(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        record = await client.find("alpha")
    assert record.handle == 5
    assert record.state is p.ServiceState.STARTED


async def test_missing_service_raises(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        with pytest.raises(ServiceNotFound):
            await client.find("missing")


async def test_status(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        status = await client.status("alpha")
    assert status.pid == 321


async def test_start_buffers_event_for_subscriber(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        await client.start("alpha")
        event = await client.subscribe().receive()
    assert isinstance(event, p.ServiceEventInfo)
    assert event.event is p.ServiceEvent.STARTED


async def test_catlog(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        log = await client.catlog("alpha")
    assert log == b"hello log\n"


async def test_get_all_env(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        env = await client.get_all_env()
    assert env == {"HOME": "/root"}


async def test_query_load_mech(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        mech = await client.query_load_mech()
    assert mech.cwd == "/work"
    assert mech.dirs == ("/store/services", "/runtime/services")


async def test_setenv(tmp_path: Path) -> None:
    async with connected_client(tmp_path) as client:
        await client.setenv({"A": "1", "B": None})
