"""A Textual TUI for dinit services managed by dinix.

The app owns one control connection for its whole life. A worker registers
every loaded service (which is what makes dinit send events for it), then two
tasks share the connection: one drains the event stream into the table and the
log, one runs commands the UI queues.
"""

from __future__ import annotations

import argparse
import os
import subprocess
from collections.abc import Awaitable, Callable
from contextlib import AbstractAsyncContextManager, suppress
from dataclasses import dataclass

import anyio
from anyio import Path as AsyncPath
from anyio.abc import ByteReceiveStream
from dinit_client import CommandRejected, DinitClient, DinitError
from dinit_client import protocol as p
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.coordinate import Coordinate
from textual.widgets import DataTable, Footer, Header, RichLog

Connector = Callable[[str | None], AbstractAsyncContextManager[DinitClient]]
Rebuilder = Callable[[], Awaitable[str]]


class RebuildError(Exception):
    """The rebuild command did not yield a usable configuration directory."""


# The symbolic link under the runtime directory that the wrapper searches for
# service descriptions, and that a nix reload repoints at the latest build.
_POINTER = "current"


@dataclass(frozen=True)
class Command:
    action: str
    service: str | None = None


_ICONS: dict[p.ServiceState, str] = {
    p.ServiceState.STARTED: "▶",
    p.ServiceState.STOPPED: "■",
    p.ServiceState.STARTING: "…",
    p.ServiceState.STOPPING: "…",
}


def _default_runtime_dir(socket_path: str | None) -> str | None:
    """Where the wrapper keeps the pointer, guessed from the environment.

    The wrapper puts the socket at ``<DINIX_RUNTIME_DIR>/control``, so the
    socket's directory is that runtime directory. With no socket on the command
    line, the environment still names it.
    """
    if socket_path is not None:
        return os.path.dirname(os.path.abspath(socket_path))
    runtime_dir = os.environ.get("DINIX_RUNTIME_DIR")
    return None if runtime_dir is None else os.path.abspath(runtime_dir)


class DinixApp(App[None]):
    TITLE = "dinix"

    CSS = """
    Horizontal { height: 1fr; }
    #services { width: 2fr; }
    #log { width: 3fr; border-left: solid $accent; }
    """

    BINDINGS = [
        Binding("s", "start", "Start"),
        Binding("x", "stop", "Stop"),
        Binding("r", "restart", "Restart"),
        Binding("R", "reload", "Reload"),
        Binding("l", "log", "Log"),
        Binding("f", "follow", "Follow"),
        Binding("n", "nix_reload", "Nix reload"),
        Binding("A", "rebuild", "Reload all"),
        Binding("f5", "refresh", "Refresh"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(
        self,
        socket_path: str | None = None,
        connector: Connector | None = None,
        *,
        nix_command: str | None = None,
        runtime_dir: str | None = None,
        rebuilder: Rebuilder | None = None,
    ) -> None:
        super().__init__()
        self._socket_path = socket_path
        self._connector: Connector = connector or DinitClient.connect
        self._nix_command = (
            nix_command if nix_command is not None else os.environ.get("DINIX_TUI_NIX_COMMAND")
        )
        self._runtime_dir = (
            runtime_dir if runtime_dir is not None else _default_runtime_dir(socket_path)
        )
        self._rebuilder = rebuilder
        self._selected: str | None = None
        self._following: str | None = None
        self._known: set[str] = set()
        self._handle_names: dict[int, str] = {}
        self._commands_send, self._commands = anyio.create_memory_object_stream(32)

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            yield DataTable(id="services")
            yield RichLog(id="log", markup=True, wrap=True, max_lines=2000)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self._socket_path or "default socket"
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns(("", "icon"), ("Service", "service"), ("State", "state"), ("PID", "pid"))
        self._run_client()
        self.set_interval(3.0, self.action_refresh)
        # dinit has no push for service output, so following is a poll of the
        # log buffer with the clear bit set.
        self.set_interval(0.5, self._follow_tick)

    # -- connection worker ----------------------------------------------

    @work(exclusive=True, exit_on_error=False, name="dinit")
    async def _run_client(self) -> None:
        try:
            async with self._connector(self._socket_path) as client:
                self._log(f"[green]connected[/green], control protocol {client.protocol_version}")
                await self._load_every_service(client)
                async with anyio.create_task_group() as group:
                    group.start_soon(self._consume_commands, client)
                    group.start_soon(self._consume_events, client)
        except DinitError as error:
            self._log(f"[red]dinit: {error}[/red]")
            self.notify(str(error), title="dinit", severity="error")
        except Exception as error:  # a crash must show, not leave a dead screen
            self._log(f"[red]tui: {error!r}[/red]")
            self.notify(repr(error), title="tui", severity="error")

    async def _load_every_service(self, client: DinitClient) -> None:
        # dinit lists only the services it has loaded, so the names have to
        # come from the directories it searches. Resolving a handle is what
        # makes dinit send events, so load every name found.
        mech = await client.query_load_mech()
        names: set[str] = set(await client.list_services())
        for directory in mech.dirs:
            path = AsyncPath(directory)
            if await path.is_dir():
                names.update(await self._names_in(path))
        for name in sorted(names):
            record = await client.load(name)
            self._handle_names[record.handle] = name
        await self._refresh(client)
        self._log(f"loaded {len(names)} service(s)")

    async def _refresh(self, client: DinitClient) -> None:
        for name, status in (await client.list_services()).items():
            self._set_row(name, status)

    async def _consume_events(self, client: DinitClient) -> None:
        async for event in client.subscribe():
            if isinstance(event, p.ServiceEventInfo):
                name = self._handle_names.get(event.handle)
                if name is None:
                    continue
                self._log(f"{name}: {event.event.name.lower()} ({event.status.state.name.lower()})")
                self._set_row(name, event.status)
            else:
                self._log(f"env {event.name}")

    async def _consume_commands(self, client: DinitClient) -> None:
        async for command in self._commands:
            try:
                if command.action == "follow" and command.service is not None:
                    await self._stream_log(client, command.service)
                    continue
                if command.action == "nix-reload":
                    await self._nix_reload(client)
                elif command.action == "rebuild-all":
                    await self._nix_reload(client, restart_running=True)
                elif command.action == "catlog" and command.service is not None:
                    data = await client.catlog(command.service)
                    self._log(data.decode("utf-8", "replace").rstrip() or "(empty log)")
                elif command.service is not None:
                    await self._effect(client, command.action, command.service)
                await self._refresh(client)
            except (DinitError, RebuildError, OSError) as error:
                detail = str(error) or type(error).__name__
                self._log(f"[red]{command.action} failed: {detail}[/red]")

    async def _stream_log(self, client: DinitClient, service: str) -> None:
        # The clear bit makes each poll return only what is new since the
        # last one, which is the closest dinit gets to a log stream.
        try:
            data = await client.catlog(service, clear=True)
        except CommandRejected:
            if self._following == service:
                self._following = None
                self.notify(f"{service} has no log buffer", severity="warning")
                self._log(f"[yellow]{service} has no log buffer[/yellow]")
            return
        if not data:
            return
        log = self.query_one(RichLog)
        for line in data.decode("utf-8", "replace").splitlines():
            log.write(Text.assemble((f"{service}| ", "dim"), line))

    async def _effect(self, client: DinitClient, action: str, service: str) -> None:
        if action == "start":
            await client.start(service)
        elif action == "stop":
            await client.stop(service, force=True)
        elif action == "restart":
            await client.restart(service)
        elif action == "reload":
            await client.reload(service)
        else:
            self._log(f"[yellow]unknown action {action!r}[/yellow]")

    # -- nix reload ------------------------------------------------------

    async def _nix_reload(self, client: DinitClient, *, restart_running: bool = False) -> None:
        """Rebuild the configuration, adopt it, and reload every service.

        A reload swaps a description; a running process keeps running. With
        ``restart_running``, every service that is started is restarted after
        the reload, so the running set comes up on the new build.
        """
        self.notify("Rebuilding...")
        self._log("nix reload: running the rebuild command")
        config_dir = await self._rebuild()
        services = AsyncPath(config_dir) / "services"
        if not await services.is_dir():
            raise RebuildError(f"{config_dir} has no services directory")
        await self._point_at(services)
        self._log(f"nix reload: adopted {config_dir}")

        known = set(self._handle_names.values())
        for name in sorted(await self._names_in(services)):
            if name in known:
                continue
            record = await client.load(name)
            self._handle_names[record.handle] = name
            self._log(f"nix reload: loaded new service {name}")

        count = 0
        for name in sorted(set(self._handle_names.values())):
            try:
                await client.reload(name)
                count += 1
            except DinitError as error:
                self._log(f"[yellow]nix reload: {name}: {error}[/yellow]")
        self._log(f"nix reload: reloaded {count} service(s)")

        if restart_running:
            started = [
                name
                for name, status in (await client.list_services()).items()
                if status.state is p.ServiceState.STARTED
            ]
            for name in sorted(started):
                try:
                    await client.restart(name)
                    self._log(f"nix reload: restarted {name}")
                except DinitError as error:
                    self._log(f"[yellow]nix reload: restart {name}: {error}[/yellow]")
        self.notify("Nix reload complete")

    async def _rebuild(self) -> str:
        if self._rebuilder is not None:
            return await self._rebuilder()
        if self._nix_command is None:
            raise RebuildError("no rebuild command configured")
        # Nix writes evaluation and build progress to stderr, so stream both to
        # the log: a long build then shows movement instead of a silent wait.
        process = await anyio.open_process(
            ["sh", "-c", self._nix_command],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        paths: list[str] = []

        async def drain(stream: ByteReceiveStream, collect: bool) -> None:
            async for raw in stream:
                for line in raw.decode("utf-8", "replace").splitlines():
                    if collect:
                        if line.strip():
                            paths.append(line.strip())
                    else:
                        self._log_plain("nix| ", line)

        async with anyio.create_task_group() as group:
            group.start_soon(drain, process.stdout, True)
            group.start_soon(drain, process.stderr, False)
        code = await process.wait()
        if code != 0:
            raise RebuildError(f"the rebuild command exited {code}")
        if not paths:
            raise RebuildError("the rebuild command printed no path")
        return paths[-1]

    async def _point_at(self, services: AsyncPath) -> None:
        if self._runtime_dir is None:
            self._log("[yellow]nix reload: no runtime directory; left the pointer alone[/yellow]")
            return
        runtime = AsyncPath(self._runtime_dir)
        await runtime.mkdir(parents=True, exist_ok=True)
        pointer = runtime / _POINTER
        temporary = pointer.with_name(pointer.name + ".new")
        with suppress(FileNotFoundError):
            await temporary.unlink()
        await temporary.symlink_to(services)
        await temporary.rename(pointer)

    @staticmethod
    async def _names_in(services: AsyncPath) -> list[str]:
        files = [entry.name async for entry in services.iterdir() if await entry.is_file()]
        return sorted(files)

    # -- UI --------------------------------------------------------------

    def _set_row(self, name: str, status: p.ServiceStatus) -> None:
        table = self.query_one(DataTable)
        cells = (
            _ICONS.get(status.state, "?"),
            name,
            status.state.name.lower(),
            "" if status.pid is None else str(status.pid),
        )
        if name in self._known:
            for key, value in zip(("icon", "service", "state", "pid"), cells, strict=True):
                table.update_cell(name, key, value)
        else:
            table.add_row(*cells, key=name)
            self._known.add(name)

    def _log(self, message: str) -> None:
        self.query_one(RichLog).write(message)

    def _log_plain(self, prefix: str, line: str) -> None:
        # A child process's output is not markup; Text keeps brackets literal.
        self.query_one(RichLog).write(Text.assemble((prefix, "dim"), line))

    @on(DataTable.RowHighlighted)
    def _row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        self._selected = str(event.row_key.value)

    def _current_service(self) -> str | None:
        # The cursor is the source of truth. RowHighlighted may not have fired
        # yet on the first frame, and a service whose name is in the table is
        # always the one under the cursor.
        table = self.query_one(DataTable)
        coordinate = Coordinate(table.cursor_row, 0)
        if table.row_count == 0 or not table.is_valid_coordinate(coordinate):
            return self._selected
        return str(table.coordinate_to_cell_key(coordinate).row_key.value)

    def _dispatch(self, action: str) -> None:
        service = self._current_service()
        if service is None:
            self.notify("Select a service first", severity="warning")
            return
        try:
            self._commands_send.send_nowait(Command(action, service))
        except anyio.WouldBlock:
            self.notify("Command queue is full", severity="warning")

    def action_start(self) -> None:
        self._dispatch("start")

    def action_stop(self) -> None:
        self._dispatch("stop")

    def action_restart(self) -> None:
        self._dispatch("restart")

    def action_reload(self) -> None:
        self._dispatch("reload")

    def action_log(self) -> None:
        self._dispatch("catlog")

    def action_follow(self) -> None:
        service = self._current_service()
        if service is None:
            self.notify("Select a service first", severity="warning")
            return
        if self._following == service:
            self._following = None
            self.notify(f"Stopped following {service}")
            return
        self._following = service
        self.notify(f"Following {service}")
        with suppress(anyio.WouldBlock):
            self._commands_send.send_nowait(Command("follow", service))

    def _follow_tick(self) -> None:
        if self._following is None:
            return
        with suppress(anyio.WouldBlock):
            self._commands_send.send_nowait(Command("follow", self._following))

    def action_refresh(self) -> None:
        with suppress(anyio.WouldBlock):
            self._commands_send.send_nowait(Command("refresh"))

    def action_nix_reload(self) -> None:
        if self._rebuilder is None and self._nix_command is None:
            self.notify(
                "Set DINIX_TUI_NIX_COMMAND to enable nix reload",
                severity="warning",
            )
            return
        with suppress(anyio.WouldBlock):
            self._commands_send.send_nowait(Command("nix-reload"))

    def action_rebuild(self) -> None:
        if self._rebuilder is None and self._nix_command is None:
            self.notify(
                "Set DINIX_TUI_NIX_COMMAND to enable reload all",
                severity="warning",
            )
            return
        with suppress(anyio.WouldBlock):
            self._commands_send.send_nowait(Command("rebuild-all"))


def main() -> None:
    parser = argparse.ArgumentParser(prog="dinix-tui", description=__doc__)
    parser.add_argument("--socket-path", default=None, help="dinit control socket to connect to")
    parser.add_argument(
        "--nix-command",
        default=None,
        help="shell command printed path to the rebuilt config directory (nix reload)",
    )
    parser.add_argument(
        "--runtime-dir",
        default=None,
        help="directory holding the services pointer; defaults near the socket",
    )
    arguments = parser.parse_args()
    DinixApp(
        socket_path=arguments.socket_path,
        nix_command=arguments.nix_command,
        runtime_dir=arguments.runtime_dir,
    ).run()
