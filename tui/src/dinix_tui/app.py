"""A Textual TUI for dinit services managed by dinix.

The app owns one control connection for its whole life. A worker registers
every loaded service (which is what makes dinit send events for it), then two
tasks share the connection: one drains the event stream into the table and the
log, one runs commands the UI queues.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager, suppress
from dataclasses import dataclass

import anyio
from dinit_client import DinitClient, DinitError
from dinit_client import protocol as p
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import DataTable, Footer, Header, RichLog

Connector = Callable[[str | None], AbstractAsyncContextManager[DinitClient]]


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
        Binding("f5", "refresh", "Refresh"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(
        self,
        socket_path: str | None = None,
        connector: Connector | None = None,
    ) -> None:
        super().__init__()
        self._socket_path = socket_path
        self._connector: Connector = connector or DinitClient.connect
        self._selected: str | None = None
        self._known: set[str] = set()
        self._handle_names: dict[int, str] = {}
        self._commands_send, self._commands = anyio.create_memory_object_stream(32)

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            yield DataTable(id="services")
            yield RichLog(id="log", markup=True, wrap=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self._socket_path or "default socket"
        table = self.query_one(DataTable)
        table.cursor_type = "row"
        table.add_columns(("", "icon"), ("Service", "service"), ("State", "state"), ("PID", "pid"))
        self._run_client()
        self.set_interval(3.0, self.action_refresh)

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

    async def _load_every_service(self, client: DinitClient) -> None:
        # A handle is what makes dinit send events for a service, so load every
        # one, remembering which handle belongs to which name.
        services = await client.list_services()
        for name in services:
            record = await client.load(name)
            self._handle_names[record.handle] = name
        await self._refresh(client)
        self._log(f"loaded {len(services)} service(s)")

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
                if command.action == "catlog" and command.service is not None:
                    data = await client.catlog(command.service)
                    self._log(data.decode("utf-8", "replace").rstrip() or "(empty log)")
                elif command.service is not None:
                    await self._effect(client, command.action, command.service)
                await self._refresh(client)
            except DinitError as error:
                self._log(f"[red]{command.action} failed: {error}[/red]")

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

    @on(DataTable.RowHighlighted)
    def _row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        self._selected = str(event.row_key.value)

    def _dispatch(self, action: str) -> None:
        if self._selected is None:
            self.notify("Select a service first", severity="warning")
            return
        try:
            self._commands_send.send_nowait(Command(action, self._selected))
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

    def action_refresh(self) -> None:
        with suppress(anyio.WouldBlock):
            self._commands_send.send_nowait(Command("refresh"))


def main() -> None:
    parser = argparse.ArgumentParser(prog="dinix-tui", description=__doc__)
    parser.add_argument("--socket-path", default=None, help="dinit control socket to connect to")
    arguments = parser.parse_args()
    DinixApp(socket_path=arguments.socket_path).run()
