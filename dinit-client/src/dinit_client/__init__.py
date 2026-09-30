"""An AnyIO client for the dinit control socket protocol."""

from . import protocol
from .client import (
    BadRequest,
    CommandRejected,
    Dependents,
    DinitClient,
    DinitConnectionClosed,
    DinitError,
    OutOfMemory,
    Pinned,
    ProtocolError,
    ServiceDescriptionError,
    ServiceLoadError,
    ServiceNotFound,
    ShuttingDown,
    SignalNotDelivered,
    default_socket_path,
)

__all__ = [
    "BadRequest",
    "CommandRejected",
    "Dependents",
    "DinitClient",
    "DinitConnectionClosed",
    "DinitError",
    "OutOfMemory",
    "Pinned",
    "ProtocolError",
    "ServiceDescriptionError",
    "ServiceLoadError",
    "ServiceNotFound",
    "ShuttingDown",
    "SignalNotDelivered",
    "default_socket_path",
    "protocol",
]
