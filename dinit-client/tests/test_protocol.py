from __future__ import annotations

import struct

import pytest

from dinit_client import protocol as p


def test_query_version_encodes_command_only():
    assert p.query_version() == bytes([p.Command.QUERYVERSION])


def test_find_or_load_encodes_length_prefixed_name():
    payload = p.find_or_load("hello", load=True)
    assert payload[0] == p.Command.LOADSERVICE
    assert struct.unpack_from("=H", payload, 1)[0] == 5
    assert payload[3:] == b"hello"
    assert p.find_or_load("hello", load=False)[0] == p.Command.FINDSERVICE


def test_find_or_load_rejects_empty_and_overlong_names():
    with pytest.raises(ValueError):
        p.find_or_load("", load=True)
    with pytest.raises(ValueError):
        p.find_or_load("x" * 1022, load=True)


def test_start_stop_sets_flag_bits():
    packed = p.start_stop(p.Command.STOPSERVICE, 7, pin=True, gentle=True, restart=True)
    assert packed[0] == p.Command.STOPSERVICE
    assert packed[1] == 0x01 | 0x02 | 0x04
    assert struct.unpack_from("=I", packed, 2)[0] == 7


def test_signal_layout_is_signal_then_handle():
    packed = p.signal_service(9, 15)
    assert packed[0] == p.Command.SIGNAL
    assert struct.unpack_from("@i", packed, 1)[0] == 15
    assert struct.unpack_from("=I", packed, 5)[0] == 9


def test_setenv_rejects_malformed_variable():
    with pytest.raises(ValueError):
        p.setenv("=oops")
    assert p.setenv("A=B")[0] == p.Command.SETENV


def test_decode_version():
    version = p.decode_version(struct.pack("=HH", 1, 7))
    assert version == p.Version(min_compat=1, protocol=7)


def test_decode_service_record():
    record = p.decode_service_record(
        bytes([p.ServiceState.STARTED]) + struct.pack("=I", 42) + bytes([p.ServiceState.STARTED])
    )
    assert record.handle == 42
    assert record.state is p.ServiceState.STARTED


def _status5(
    state: p.ServiceState, flags: int, reason: p.StoppedReason, code: int, status: int
) -> bytes:
    buf = bytearray(p.STATUS5_SIZE)
    buf[0] = state
    buf[1] = state
    buf[2] = flags
    buf[3] = reason
    struct.pack_into("@i", buf, 6, code)
    struct.pack_into("@i", buf, 10, status)
    return bytes(buf)


def test_decode_status5_with_pid():
    buf = _status5(
        p.ServiceState.STARTED,
        p.FLAG_HAS_PID | p.FLAG_MARKED_ACTIVE,
        p.StoppedReason.NORMAL,
        1234,
        0,
    )
    status = p.decode_status(buf, 5)
    assert status.pid == 1234
    assert status.active
    assert status.si_code is None


def test_decode_status5_exit_from_signal():
    buf = _status5(p.ServiceState.STOPPED, 0, p.StoppedReason.FAILED, 9, 15)
    status = p.decode_status(buf, 5)
    assert status.si_code == 9
    assert status.si_status == 15


def test_decode_status6_carries_mod_time():
    buf = bytearray(p.STATUS6_SIZE)
    buf[0] = p.ServiceState.STOPPED
    buf[1] = p.ServiceState.STOPPED
    buf[2] = 0
    buf[3] = p.StoppedReason.NORMAL
    struct.pack_into("@ll", buf, p.STATUS5_SIZE, 100, 500_000_000)
    status = p.decode_status(buf, 6)
    assert status.mod_time == 100.5


def test_decode_loader_mech_reads_cwd_and_dirs():
    cwd = b"/work"
    dirs = [b"/a/services", b"/b/services"]
    body = (
        struct.pack("=II", len(dirs), len(cwd))
        + cwd
        + b"".join(struct.pack("=I", len(d)) + d for d in dirs)
    )
    size = 6 + len(body)
    packet = bytes([p.Reply.LOADER_MECH, p.LoaderType.DIRLOAD]) + struct.pack("=I", size) + body
    mech = p.decode_loader_mech(packet)
    assert mech.cwd == "/work"
    assert mech.dirs == ("/a/services", "/b/services")


def test_decode_allenv():
    block = b"A=1\0B=two\0"
    payload = struct.pack("@L", len(block)) + block
    assert p.decode_allenv(payload) == {"A": "1", "B": "two"}


def test_decode_service_event5():
    status = _status5(p.ServiceState.STARTED, p.FLAG_HAS_PID, p.StoppedReason.NORMAL, 99, 0)
    payload = struct.pack("=I", 3) + bytes([p.ServiceEvent.STARTED]) + status
    event = p.decode_service_event5(payload)
    assert event.handle == 3
    assert event.event is p.ServiceEvent.STARTED
    assert event.status.pid == 99


def test_decode_env_event():
    raw = b"HOME=/root"
    payload = bytes([1]) + struct.pack("=H", len(raw)) + raw
    event = p.decode_env_event(payload)
    assert event.name == "HOME=/root"
    assert event.overridden
