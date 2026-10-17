"""Error types for the `pq` package.

Defines `PgErrorKind`, a small `Int` newtype enumerating the seven failure
categories the package can report, and `PgError`, the single error type raised
by `pq` APIs via typed `raises PgError`.
"""


@fieldwise_init
struct PgErrorKind(Equatable, TrivialRegisterPassable, Writable):
    """Category of a `PgError`.

    An `Int` newtype with exactly seven constants: `LIBPQ_LOAD`, `CONNECTION`,
    `SERVER`, `NULL_VALUE`, `TYPE_MISMATCH`, `USAGE` and `TIMEOUT`.
    """

    var value: Int
    """Numeric discriminant of the kind."""

    comptime LIBPQ_LOAD = Self(0)
    """Libpq itself could not be loaded."""

    comptime CONNECTION = Self(1)
    """Connecting failed, or the connection is no longer usable."""

    comptime SERVER = Self(2)
    """The server rejected a statement and reported a diagnostic."""

    comptime NULL_VALUE = Self(3)
    """A non-optional value was requested from a SQL NULL."""

    comptime TYPE_MISMATCH = Self(4)
    """The requested shape does not match the result (type, index or name).

    Also covers an argument libpq cannot be handed at all, namely text with an
    embedded NUL byte.
    """

    comptime USAGE = Self(5)
    """The caller misused the `pq` API.

    Detected client-side; nothing was sent to the server, so `sqlstate` and
    the other diagnostics are empty.
    """

    comptime TIMEOUT = Self(6)
    """The state change being waited for did not arrive within `timeout_ms`.

    Raised only by the asynchronous API's blocking helpers. The connection is
    untouched and still usable: the statement is simply still running, so the
    caller can keep waiting, or `cancel()` it.
    """

    def __eq__(self, other: Self) -> Bool:
        """Compare two kinds for equality.

        Args:
            other: The kind to compare against.

        Returns:
            True if both kinds have the same discriminant.
        """
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Compare two kinds for inequality.

        Args:
            other: The kind to compare against.

        Returns:
            True if the kinds have different discriminants.
        """
        return self.value != other.value

    def write_to(self, mut writer: Some[Writer]):
        """Write the kind's name to `writer`.

        Args:
            writer: The writer receiving the kind name.
        """
        if self == Self.LIBPQ_LOAD:
            writer.write("LibpqLoad")
        elif self == Self.CONNECTION:
            writer.write("Connection")
        elif self == Self.SERVER:
            writer.write("Server")
        elif self == Self.NULL_VALUE:
            writer.write("NullValue")
        elif self == Self.TYPE_MISMATCH:
            writer.write("TypeMismatch")
        elif self == Self.USAGE:
            writer.write("Usage")
        elif self == Self.TIMEOUT:
            writer.write("Timeout")


struct PgError(Copyable, Writable):
    """Error raised by `pq` APIs.

    Carries a `PgErrorKind` plus a human-readable message and the optional
    diagnostic fields libpq exposes for server errors.
    """

    var kind: PgErrorKind
    """Failure category."""

    var message: String
    """Human-readable description of the failure."""

    var sqlstate: String
    """SQLSTATE code reported by the server, or empty."""

    var severity: String
    """Server-reported severity, or empty."""

    var detail: String
    """Server-reported detail text, or empty."""

    var hint: String
    """Server-reported hint text, or empty."""

    var position: String
    """Server-reported error position in the statement, or empty."""

    var context: String
    """Server-reported error context, or empty."""

    def __init__(
        out self,
        kind: PgErrorKind,
        message: String,
        sqlstate: String = "",
        severity: String = "",
        detail: String = "",
        hint: String = "",
        position: String = "",
        context: String = "",
    ):
        """Construct a `PgError`.

        Args:
            kind: Failure category.
            message: Human-readable description of the failure.
            sqlstate: SQLSTATE code reported by the server.
            severity: Server-reported severity.
            detail: Server-reported detail text.
            hint: Server-reported hint text.
            position: Server-reported error position in the statement.
            context: Server-reported error context.
        """
        self.kind = kind
        self.message = message
        self.sqlstate = sqlstate
        self.severity = severity
        self.detail = detail
        self.hint = hint
        self.position = position
        self.context = context

    def write_to(self, mut writer: Some[Writer]):
        """Write a readable representation of the error to `writer`.

        The `sqlstate` item is omitted when `sqlstate` is empty.

        Args:
            writer: The writer receiving the representation.
        """
        writer.write("PgError(kind=", self.kind)
        if self.sqlstate != "":
            writer.write(", sqlstate=", self.sqlstate)
        writer.write(", message=", self.message, ")")


def _reject_nul(s: String, what: StaticString) raises PgError:
    """Reject caller text that libpq could only receive truncated.

    libpq takes C strings, and `String.as_c_string_span()` stops at the first
    NUL byte, so a value with an embedded NUL would be silently cut there
    instead of refused. Every `pq` entry point that hands caller text to libpq
    runs this first, which turns that silent truncation into an error.

    Args:
        s: The argument to inspect.
        what: Name of the argument, used in the message. The value itself is
            never included, so a password cannot leak through the error.

    Raises:
        PgError: `PgErrorKind.TYPE_MISMATCH` when `s` contains a NUL byte.
    """
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == 0:
            raise PgError(
                PgErrorKind.TYPE_MISMATCH,
                String("embedded NUL byte in ", what),
            )
