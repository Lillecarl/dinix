"""An AnyIO client for the dinit control socket.

One connection carries several commands and receives service events for every
service it has resolved a handle to. Commands are serialised on the connection
because the daemon does not tag replies with a request id; the reader task
matches the next reply to the one command in flight.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass, field

import anyio
from anyio import (
    BrokenResourceError,
    ClosedResourceError,
    EndOfStream,
    WouldBlock,
)
from anyio.abc import SocketStream
from anyio.streams.memory import MemoryObjectReceiveStream

from . import protocol as p

_SYSTEM_SOCKET = "/run/dinitctl"

# Events buffer until a subscriber drains them, so an event arriving just
# before subscribe() is not lost. A full buffer drops the newest event, since a
# stuck consumer must not stall the control connection.
_EVENT_BUFFER = 64


class DinitError(Exception):
    """Base class for every error this client raises."""


class DinitConnectionClosed(DinitError):
    pass


class ProtocolError(DinitError):
    pass


class CommandRejected(DinitError):
    """The daemon answered NAK."""


class BadRequest(DinitError):
    pass


class OutOfMemory(DinitError):
    pass


class ShuttingDown(DinitError):
    pass


class Pinned(DinitError):
    pass


class Dependents(DinitError):
    def __init__(self, handles: tuple[int, ...]) -> None:
        super().__init__(f"service has {len(handles)} dependent(s)")
        self.handles = handles


class ServiceNotFound(DinitError):
    pass


class ServiceLoadError(DinitError):
    pass


class ServiceDescriptionError(DinitError):
    pass


class SignalNotDelivered(DinitError):
    pass


_SIMPLE_ERRORS: dict[p.Reply, type[DinitError]] = {
    p.Reply.NAK: CommandRejected,
    p.Reply.BADREQ: BadRequest,
    p.Reply.OOM: OutOfMemory,
    p.Reply.SERVICEOOM: OutOfMemory,
    p.Reply.SHUTTINGDOWN: ShuttingDown,
    p.Reply.PINNEDSTOPPED: Pinned,
    p.Reply.PINNEDSTARTED: Pinned,
    p.Reply.NOSERVICE: ServiceNotFound,
    p.Reply.SERVICE_DESC_ERR: ServiceDescriptionError,
    p.Reply.SERVICE_LOAD_ERR: ServiceLoadError,
    p.Reply.SERVICELOADERR: ServiceLoadError,
    p.Reply.SIGNAL_NOPID: SignalNotDelivered,
    p.Reply.SIGNAL_BADSIG: SignalNotDelivered,
    p.Reply.SIGNAL_KILLERR: SignalNotDelivered,
}


def default_socket_path() -> str:
    """The path dinitctl would use with the same environment and uid."""
    override = os.environ.get("DINIT_SOCKET_PATH")
    if override:
        return override
    if os.geteuid() == 0:
        return _SYSTEM_SOCKET
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if runtime_dir:
        return os.path.join(runtime_dir, "dinitctl")
    home = os.environ.get("HOME")
    if home:
        return os.path.join(home, ".dinitctl")
    raise DinitError("cannot determine the dinit control socket path")


class _Reader:
    __slots__ = ("_stream",)

    def __init__(self, stream: SocketStream) -> None:
        self._stream = stream

    async def exactly(self, count: int) -> bytes:
        parts: list[bytes] = []
        remaining = count
        while remaining > 0:
            chunk = await self._stream.receive(remaining)
            parts.append(chunk)
            remaining -= len(chunk)
        return b"".join(parts)

    async def byte(self) -> int:
        return (await self.exactly(1))[0]


@dataclass
class _Pending:
    handler: Callable[[int, _Reader, _Pending], Awaitable[None]]
    result: object = None
    error: BaseException | None = None
    done: anyio.Event = field(default_factory=anyio.Event)


class DinitClient:
    """A connected dinit control client. Use :meth:`connect`."""

    def __init__(self, stream: SocketStream) -> None:
        self._stream = stream
        self._reader = _Reader(stream)
        self._lock = anyio.Lock()
        self._pending: _Pending | None = None
        self._closed = False
        self._version = 1
        self._events_send, self._events_recv = anyio.create_memory_object_stream(_EVENT_BUFFER)

    @property
    def protocol_version(self) -> int:
        return self._version

    @classmethod
    @asynccontextmanager
    async def connect(
        cls,
        socket_path: str | None = None,
        *,
        min_version: int = 1,
    ) -> AsyncIterator[DinitClient]:
        path = socket_path or default_socket_path()
        stream = await anyio.connect_unix(path)
        client = cls(stream)
        try:
            async with anyio.create_task_group() as task_group:
                task_group.start_soon(client._read_loop)
                version = await client._negotiate(min_version)
                client._version = version
                try:
                    yield client
                finally:
                    task_group.cancel_scope.cancel()
        finally:
            await stream.aclose()

    def subscribe(self) -> MemoryObjectReceiveStream[p.Event]:
        """Receive service and environment events as they arrive."""
        return self._events_recv

    # -- command surface -------------------------------------------------

    async def list_services(self) -> dict[str, p.ServiceStatus]:
        async def handler(reply: int, reader: _Reader, pending: _Pending) -> None:
            if reply != p.Reply.SVCINFO:
                self._reject(reply, pending)
                return
            items: dict[str, p.ServiceStatus] = {}
            while True:
                namelen = await reader.byte()
                status = p.decode_status(
                    await reader.exactly(self._list_status_size),
                    min(self._version, 5),
                )
                items[(await reader.exactly(namelen)).decode()] = status
                reply = await self._next_reply()
                if reply == p.Reply.LISTDONE:
                    break
                if reply != p.Reply.SVCINFO:
                    self._reject(reply, pending)
                    return
            pending.result = items
            pending.done.set()

        return await self._request(p.list_services(self._version), handler)

    async def load(self, name: str) -> p.ServiceRecord:
        return await self._record_request(p.find_or_load(name, load=True))

    async def find(self, name: str) -> p.ServiceRecord:
        return await self._record_request(p.find_or_load(name, load=False))

    async def handle_for(self, name: str) -> int:
        return (await self.find(name)).handle

    async def reload(self, name: str) -> None:
        handle = await self.handle_for(name)
        await self._request(
            p.service_handle_command(p.Command.RELOADSERVICE, handle), self._ack_handler
        )

    async def unload(self, name: str) -> None:
        handle = await self.handle_for(name)
        await self._request(
            p.service_handle_command(p.Command.UNLOADSERVICE, handle), self._ack_handler
        )

    async def start(self, name: str, *, pin: bool = False) -> None:
        handle = (await self.load(name)).handle
        await self._request(
            p.start_stop(p.Command.STARTSERVICE, handle, pin=pin), self._ack_handler
        )

    async def stop(self, name: str, *, pin: bool = False, force: bool = False) -> None:
        handle = await self.handle_for(name)
        payload = p.start_stop(p.Command.STOPSERVICE, handle, pin=pin, gentle=not force)
        await self._request(payload, self._stop_handler)

    async def restart(self, name: str) -> None:
        handle = await self.handle_for(name)
        await self._request(
            p.start_stop(p.Command.STOPSERVICE, handle, restart=True), self._ack_handler
        )

    async def wake(self, name: str, *, pin: bool = False) -> None:
        handle = await self.handle_for(name)
        await self._request(p.start_stop(p.Command.WAKESERVICE, handle, pin=pin), self._ack_handler)

    async def release(self, name: str) -> None:
        handle = await self.handle_for(name)
        await self._request(p.start_stop(p.Command.RELEASESERVICE, handle), self._ack_handler)

    async def unpin(self, name: str) -> None:
        handle = await self.handle_for(name)
        await self._request(p.unpin(handle), self._ack_handler)

    async def status(self, name: str) -> p.ServiceStatus:
        handle = await self.handle_for(name)
        size = self._status_size

        async def handler(reply: int, reader: _Reader, pending: _Pending) -> None:
            if reply != p.Reply.SERVICESTATUS:
                self._reject(reply, pending)
                return
            await reader.exactly(1)  # reserved
            pending.result = p.decode_status(await reader.exactly(size), self._version)
            pending.done.set()

        return await self._request(p.service_status(handle, self._version), handler)

    async def catlog(self, name: str, *, clear: bool = False) -> bytes:
        handle = await self.handle_for(name)

        async def handler(reply: int, reader: _Reader, pending: _Pending) -> None:
            if reply != p.Reply.SERVICE_LOG:
                self._reject(reply, pending)
                return
            head = await reader.exactly(5)
            length = p.unpack_u32(head, 1)
            pending.result = await reader.exactly(length)
            pending.done.set()

        return await self._request(p.catlog(handle, clear=clear), handler)

    async def signal(self, name: str, signum: int) -> None:
        handle = await self.handle_for(name)
        await self._request(p.signal_service(handle, signum), self._ack_handler)

    async def setenv(self, variables: Mapping[str, str | None]) -> None:
        for name, value in variables.items():
            payload = p.setenv(name if value is None else f"{name}={value}")
            await self._request(payload, self._ack_handler)

    async def get_all_env(self) -> dict[str, str]:
        async def handler(reply: int, reader: _Reader, pending: _Pending) -> None:
            if reply != p.Reply.ALLENV:
                self._reject(reply, pending)
                return
            head = await reader.exactly(p.SIZE_T)
            length = p.unpack_size_t(head)
            pending.result = p.decode_allenv(head + await reader.exactly(length))
            pending.done.set()

        return await self._request(p.get_all_env(), handler)

    async def query_load_mech(self) -> p.LoaderMech:
        async def handler(reply: int, reader: _Reader, pending: _Pending) -> None:
            if reply != p.Reply.LOADER_MECH:
                self._reject(reply, pending)
                return
            head = await reader.exactly(5)  # loader type + packet size
            size = p.unpack_u32(head, 1)
            packet = bytes([p.Reply.LOADER_MECH]) + head + await reader.exactly(size - 6)
            pending.result = p.decode_loader_mech(packet)
            pending.done.set()

        return await self._request(p.query_load_mech(), handler)

    # -- internals -------------------------------------------------------

    @property
    def _status_size(self) -> int:
        if self._version >= 6:
            return p.STATUS6_SIZE
        if self._version >= 5:
            return p.STATUS5_SIZE
        return p.STATUS_SIZE

    @property
    def _list_status_size(self) -> int:
        return p.STATUS5_SIZE if self._version >= 5 else p.STATUS_SIZE

    async def _negotiate(self, min_version: int) -> int:
        version = await self._request(p.query_version(), _version_handler)
        if not isinstance(version, p.Version):
            raise ProtocolError("no version reply")
        if version.min_compat > p.MAX_PROTOCOL:
            raise ProtocolError(
                f"daemon requires protocol {version.min_compat}, client speaks {p.MAX_PROTOCOL}"
            )
        if version.protocol < min_version:
            raise ProtocolError(f"daemon speaks protocol {version.protocol}, need {min_version}")
        return version.protocol

    async def _request(
        self,
        payload: bytes,
        handler: Callable[[int, _Reader, _Pending], Awaitable[None]],
    ) -> object:
        async with self._lock:
            if self._closed:
                raise DinitConnectionClosed("connection is closed")
            pending = _Pending(handler)
            self._pending = pending
            try:
                await self._stream.send(payload)
            except (BrokenResourceError, ClosedResourceError) as exc:
                self._pending = None
                raise DinitConnectionClosed("connection closed while sending") from exc
            await pending.done.wait()
            self._pending = None
            if pending.error is not None:
                raise pending.error
            return pending.result

    def _reject(self, reply: int, pending: _Pending) -> None:
        pending.error = _SIMPLE_ERRORS.get(
            p.Reply(reply), ProtocolError(f"unexpected reply {reply}")
        )
        pending.done.set()

    async def _record_request(self, payload: bytes) -> object:
        async def handler(reply: int, reader: _Reader, pending: _Pending) -> None:
            if reply != p.Reply.SERVICERECORD:
                self._reject(reply, pending)
                return
            pending.result = p.decode_service_record(await reader.exactly(6))
            pending.done.set()

        return await self._request(payload, handler)

    async def _ack_handler(self, reply: int, _reader: _Reader, pending: _Pending) -> None:
        if reply in (p.Reply.ACK, p.Reply.ALREADYSS):
            pending.result = None
            pending.done.set()
            return
        self._reject(reply, pending)

    async def _stop_handler(self, reply: int, reader: _Reader, pending: _Pending) -> None:
        if reply != p.Reply.DEPENDENTS:
            await self._ack_handler(reply, reader, pending)
            return
        count = p.unpack_size_t(await reader.exactly(p.SIZE_T))
        collected = [p.unpack_u32(await reader.exactly(4)) for _ in range(count)]
        pending.error = Dependents(tuple(collected))
        pending.done.set()

    async def _read_loop(self) -> None:
        failure: DinitConnectionClosed | None = None
        try:
            while True:
                reply = await self._next_reply()
                pending = self._pending
                if pending is None:
                    raise ProtocolError(f"reply {reply} with no command in flight")
                await pending.handler(reply, self._reader, pending)
        except (EndOfStream, ClosedResourceError):
            failure = DinitConnectionClosed("dinit closed the control connection")
        except BrokenResourceError as exc:
            failure = DinitConnectionClosed("control connection broke")
            failure.__cause__ = exc
        finally:
            self._closed = True
            pending = self._pending
            if pending is not None:
                pending.error = failure or DinitConnectionClosed("client is closing")
                pending.done.set()
            self._events_send.close()

    async def _next_reply(self) -> int:
        while True:
            reply = await self._reader.byte()
            if reply < 100:
                return reply
            length = await self._reader.byte()
            if length < 2:
                raise ProtocolError("information packet shorter than its header")
            self._dispatch_info(reply, await self._reader.exactly(length - 2))

    def _dispatch_info(self, kind: int, payload: bytes) -> None:
        if kind == p.Info.SERVICEEVENT5:
            event: p.Event = p.decode_service_event5(payload)
        elif kind == p.Info.SERVICEEVENT and self._version < 5:
            event = p.decode_legacy_event(payload)
        elif kind == p.Info.ENVEVENT:
            event = p.decode_env_event(payload)
        else:
            return
        with suppress(WouldBlock):
            self._events_send.send_nowait(event)


async def _version_handler(reply: int, reader: _Reader, pending: _Pending) -> None:
    if reply != p.Reply.CPVERSION:
        pending.error = ProtocolError(f"unexpected reply {reply} to QUERYVERSION")
        pending.done.set()
        return
    pending.result = p.decode_version(await reader.exactly(4))
    pending.done.set()
