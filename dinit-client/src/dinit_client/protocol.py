"""Encoding and decoding for the dinit control socket protocol.

This module is pure: it names the wire values, packs request packets and
decodes reply packets. It performs no IO.

All multi-byte integers travel in the host's native byte order and, for the
C types ``int``/``pid_t``/``time_t``, at the host's native size. The daemon
and this client therefore have to share an ABI, which is the intended use:
controlling a dinit on the same machine.

Verified against dinit 0.22.1 (control protocol version 7).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum

# dinit/src/includes/control-cmds.h: the protocol version this module speaks.
MAX_PROTOCOL = 7

# Native sizes, matching the daemon's own memcpy of C values.
_SIZEOF_INT = struct.calcsize("@i")
_SIZEOF_PID = struct.calcsize("@i")
_SIZEOF_UNION = max(_SIZEOF_INT, _SIZEOF_PID)
_SIZEOF_TIMESPEC = struct.calcsize("@ll")

STATUS_SIZE = 6 + _SIZEOF_UNION
STATUS5_SIZE = 6 + 2 * _SIZEOF_INT
STATUS6_SIZE = STATUS5_SIZE + _SIZEOF_TIMESPEC

_HANDLE = struct.Struct("=I")
_NAME_LEN = struct.Struct("=H")
_U16 = struct.Struct("@H")
_INT = struct.Struct("@i")
_TIMESPEC = struct.Struct("@ll")
_SIZE_T = struct.Struct("@L")

SIZE_T = _SIZE_T.size

_SERVICE_NAME_MAX = 1024 - 3


class Command(IntEnum):
    QUERYVERSION = 0
    FINDSERVICE = 1
    LOADSERVICE = 2
    STARTSERVICE = 3
    STOPSERVICE = 4
    WAKESERVICE = 5
    RELEASESERVICE = 6
    UNPINSERVICE = 7
    LISTSERVICES = 8
    UNLOADSERVICE = 9
    SHUTDOWN = 10
    ADD_DEP = 11
    REM_DEP = 12
    QUERY_LOAD_MECH = 13
    ENABLESERVICE = 14
    QUERYSERVICENAME = 15
    RELOADSERVICE = 16
    SETENV = 17
    SERVICESTATUS = 18
    SETTRIGGER = 19
    CATLOG = 20
    SIGNAL = 21
    QUERYSERVICEDSCDIR = 22
    CLOSEHANDLE = 23
    GETALLENV = 24
    LISTSERVICES5 = 25
    SERVICESTATUS5 = 26
    LISTENENV = 27
    SERVICESTATUS6 = 28
    ENABLE_SERVICE_V7 = 29
    REM_DEP_V7 = 30


class Reply(IntEnum):
    ACK = 50
    NAK = 51
    BADREQ = 52
    OOM = 53
    SERVICELOADERR = 54
    SERVICEOOM = 55
    CPVERSION = 58
    SERVICERECORD = 59
    NOSERVICE = 60
    ALREADYSS = 61
    SVCINFO = 62
    LISTDONE = 63
    LOADER_MECH = 64
    DEPENDENTS = 65
    SERVICENAME = 66
    PINNEDSTOPPED = 67
    PINNEDSTARTED = 68
    SHUTTINGDOWN = 69
    SERVICESTATUS = 70
    SERVICE_DESC_ERR = 71
    SERVICE_LOAD_ERR = 72
    SERVICE_LOG = 73
    SIGNAL_NOPID = 74
    SIGNAL_BADSIG = 75
    SIGNAL_KILLERR = 76
    SVCDSCDIR = 77
    ALLENV = 78
    PREACK = 79


class Info(IntEnum):
    SERVICEEVENT = 100
    SERVICEEVENT5 = 101
    ENVEVENT = 102


class ServiceState(IntEnum):
    STOPPED = 0
    STARTING = 1
    STARTED = 2
    STOPPING = 3


class ServiceType(IntEnum):
    PLACEHOLDER = 0
    PROCESS = 1
    BGPROCESS = 2
    SCRIPTED = 3
    INTERNAL = 4
    TRIGGERED = 5


class StoppedReason(IntEnum):
    NORMAL = 0
    DEPRESTART = 1
    DEPFAILED = 2
    FAILED = 3
    EXECFAILED = 4
    TIMEDOUT = 5
    TERMINATED = 6


class ServiceEvent(IntEnum):
    STARTED = 0
    STOPPED = 1
    FAILEDSTART = 2
    STARTCANCELLED = 3
    STOPCANCELLED = 4


class LoaderType(IntEnum):
    NONE = 0
    DIRLOAD = 1


class DependencyType(IntEnum):
    REGULAR = 0
    SOFT = 1
    WAITS_FOR = 2
    MILESTONE = 3
    BEFORE = 4
    AFTER = 5
    PREPARED_BY = 6


class ShutdownType(IntEnum):
    REMAIN = 0
    HALT = 1
    POWEROFF = 2
    REBOOT = 3
    SOFTREBOOT = 4
    KEXEC = 5


# Status flag bits (control.cc fill_status_buffer).
FLAG_WAITING_FOR_CONSOLE = 0x01
FLAG_HAS_CONSOLE = 0x02
FLAG_START_SKIPPED = 0x04
FLAG_MARKED_ACTIVE = 0x08
FLAG_HAS_PID = 0x10


@dataclass(frozen=True, slots=True)
class Version:
    min_compat: int
    protocol: int


@dataclass(frozen=True, slots=True)
class ServiceRecord:
    state: ServiceState
    handle: int
    target_state: ServiceState


@dataclass(frozen=True, slots=True)
class ServiceStatus:
    state: ServiceState
    target_state: ServiceState
    flags: int
    stop_reason: StoppedReason
    pid: int | None = None
    si_code: int | None = None
    si_status: int | None = None
    exit_status: int | None = None
    exec_stage: int | None = None
    exec_errno: int | None = None
    mod_time: float | None = None

    @property
    def active(self) -> bool:
        return bool(self.flags & FLAG_MARKED_ACTIVE)

    @property
    def has_pid(self) -> bool:
        return bool(self.flags & FLAG_HAS_PID)


@dataclass(frozen=True, slots=True)
class LoaderMech:
    loader_type: LoaderType
    cwd: str
    dirs: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ServiceLog:
    flags: int
    data: bytes


@dataclass(frozen=True, slots=True)
class ServiceEventInfo:
    handle: int
    event: ServiceEvent
    status: ServiceStatus


@dataclass(frozen=True, slots=True)
class EnvEvent:
    name: str
    overridden: bool


Event = ServiceEventInfo | EnvEvent


def _service_name(name: str) -> bytes:
    raw = name.encode()
    if not raw:
        raise ValueError("service name must not be empty")
    if len(raw) > _SERVICE_NAME_MAX:
        raise ValueError(f"service name longer than {_SERVICE_NAME_MAX} bytes")
    return raw


def query_version() -> bytes:
    return bytes([Command.QUERYVERSION])


def find_or_load(name: str, *, load: bool) -> bytes:
    raw = _service_name(name)
    cmd = Command.LOADSERVICE if load else Command.FINDSERVICE
    return bytes([cmd]) + _NAME_LEN.pack(len(raw)) + raw


def service_handle_command(cmd: Command, handle: int) -> bytes:
    return bytes([cmd]) + _HANDLE.pack(handle)


def start_stop(
    cmd: Command,
    handle: int,
    *,
    pin: bool = False,
    gentle: bool = False,
    restart: bool = False,
    preack: bool = False,
) -> bytes:
    flags = (
        (0x01 if pin else 0)
        | (0x02 if gentle else 0)
        | (0x04 if restart else 0)
        | (0x80 if preack else 0)
    )
    return bytes([cmd, flags]) + _HANDLE.pack(handle)


def service_status(handle: int, version: int) -> bytes:
    if version >= 6:
        cmd = Command.SERVICESTATUS6
    elif version >= 5:
        cmd = Command.SERVICESTATUS5
    else:
        cmd = Command.SERVICESTATUS
    return service_handle_command(cmd, handle)


def list_services(version: int) -> bytes:
    cmd = Command.LISTSERVICES5 if version >= 5 else Command.LISTSERVICES
    return bytes([cmd])


def catlog(handle: int, *, clear: bool = False) -> bytes:
    return bytes([Command.CATLOG, 1 if clear else 0]) + _HANDLE.pack(handle)


def signal_service(handle: int, signum: int) -> bytes:
    return bytes([Command.SIGNAL]) + _INT.pack(signum) + _HANDLE.pack(handle)


def setenv(variable: str) -> bytes:
    raw = variable.encode()
    if not raw or raw[0] == ord("="):
        raise ValueError("environment variable must be NAME=VALUE or NAME")
    if len(raw) > _SERVICE_NAME_MAX:
        raise ValueError(f"environment variable longer than {_SERVICE_NAME_MAX} bytes")
    return bytes([Command.SETENV]) + _NAME_LEN.pack(len(raw)) + raw


def get_all_env() -> bytes:
    return bytes([Command.GETALLENV, 0])


def query_load_mech() -> bytes:
    return bytes([Command.QUERY_LOAD_MECH])


def unpin(handle: int) -> bytes:
    return service_handle_command(Command.UNPINSERVICE, handle)


def close_handle(handle: int) -> bytes:
    return service_handle_command(Command.CLOSEHANDLE, handle)


def decode_version(buf: bytes) -> Version:
    min_compat, protocol = struct.unpack_from("=HH", buf, 0)
    return Version(min_compat=min_compat, protocol=protocol)


def decode_service_record(buf: bytes) -> ServiceRecord:
    return ServiceRecord(
        state=ServiceState(buf[0]),
        handle=_HANDLE.unpack_from(buf, 1)[0],
        target_state=ServiceState(buf[5]),
    )


def decode_status(buf: bytes, version: int) -> ServiceStatus:
    state = ServiceState(buf[0])
    target_state = ServiceState(buf[1])
    flags = buf[2]
    stop_reason = StoppedReason(buf[3])

    pid = si_code = si_status = exit_status = exec_stage = exec_errno = None
    if stop_reason == StoppedReason.EXECFAILED:
        exec_stage = _U16.unpack_from(buf, 4)[0]
        exec_errno = _INT.unpack_from(buf, 6)[0]
    elif flags & FLAG_HAS_PID:
        pid = _INT.unpack_from(buf, 6)[0]
    elif version >= 5:
        si_code = _INT.unpack_from(buf, 6)[0]
        si_status = _INT.unpack_from(buf, 10)[0]
    else:
        exit_status = _INT.unpack_from(buf, 6)[0]

    mod_time = None
    if version >= 6:
        seconds, nanoseconds = _TIMESPEC.unpack_from(buf, STATUS5_SIZE)
        mod_time = seconds + nanoseconds / 1_000_000_000

    return ServiceStatus(
        state=state,
        target_state=target_state,
        flags=flags,
        stop_reason=stop_reason,
        pid=pid,
        si_code=si_code,
        si_status=si_status,
        exit_status=exit_status,
        exec_stage=exec_stage,
        exec_errno=exec_errno,
        mod_time=mod_time,
    )


def decode_loader_mech(packet: bytes) -> LoaderMech:
    loader_type, _size, count, cwd_len = struct.unpack_from("=BIII", packet, 1)
    pos = 1 + 1 + 4 + 4 + 4
    cwd = packet[pos : pos + cwd_len].decode()
    pos += cwd_len
    dirs: list[str] = []
    for _ in range(count):
        (length,) = struct.unpack_from("=I", packet, pos)
        pos += 4
        dirs.append(packet[pos : pos + length].decode())
        pos += length
    return LoaderMech(loader_type=LoaderType(loader_type), cwd=cwd, dirs=tuple(dirs))


def decode_log(payload: bytes) -> ServiceLog:
    flags = payload[0]
    (length,) = struct.unpack_from("=I", payload, 1)
    return ServiceLog(flags=flags, data=payload[5 : 5 + length])


def decode_allenv(payload: bytes) -> dict[str, str]:
    (length,) = struct.unpack_from("@L", payload, 0)
    block = payload[struct.calcsize("@L") : struct.calcsize("@L") + length]
    result: dict[str, str] = {}
    for entry in block.split(b"\0"):
        if not entry:
            continue
        name, _, value = entry.decode().partition("=")
        result[name] = value
    return result


def decode_service_name(payload: bytes) -> str:
    (length,) = struct.unpack_from("=H", payload, 0)
    return payload[2 : 2 + length].decode()


def decode_service_event5(payload: bytes) -> ServiceEventInfo:
    handle = _HANDLE.unpack_from(payload, 0)[0]
    event = ServiceEvent(payload[4])
    status = decode_status(payload[5:], 5)
    return ServiceEventInfo(handle=handle, event=event, status=status)


def decode_legacy_event(payload: bytes) -> ServiceEventInfo:
    handle = _HANDLE.unpack_from(payload, 0)[0]
    event = ServiceEvent(payload[4])
    status = decode_status(payload[5:], 4)
    return ServiceEventInfo(handle=handle, event=event, status=status)


def unpack_u32(buf: bytes, offset: int = 0) -> int:
    return _HANDLE.unpack_from(buf, offset)[0]


def unpack_size_t(buf: bytes, offset: int = 0) -> int:
    return _SIZE_T.unpack_from(buf, offset)[0]


def decode_env_event(payload: bytes) -> EnvEvent:
    overridden = bool(payload[0])
    (length,) = struct.unpack_from("=H", payload, 1)
    name = payload[3 : 3 + length].rstrip(b"\0").decode()
    return EnvEvent(name=name, overridden=overridden)
