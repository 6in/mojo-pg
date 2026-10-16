"""The `UUID` value type used for PostgreSQL `uuid` columns.

Holds the sixteen raw bytes of a UUID and converts between them and the
canonical lowercase `8-4-4-4-12` hex text PostgreSQL prints. Parsing is
deliberately narrower than the server's `uuid_in`: only the 36-character
hyphenated form is accepted, so neither the `{...}`-wrapped form nor the
bare 32-digit form parses here.
"""

from pq.errors import PgError, PgErrorKind

comptime _HYPHEN = UInt8(ord("-"))
comptime _UUID_TEXT_LENGTH = 16 * 2 + 4
"""Length of the canonical text form: 32 hex digits plus four hyphens."""

comptime _LOWER_HEX = "0123456789abcdef"


def _usage_error(text: String) -> PgError:
    """Build the `USAGE` error for text the checked constructor rejects."""
    return PgError(
        PgErrorKind.USAGE,
        String('invalid uuid literal "', text, '"'),
    )


def _decode_error(text: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for text that does not parse."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String('cannot decode "', text, '" as uuid'),
    )


def _hex_digit(byte: UInt8) -> Int:
    """Return the value of one hex digit, or -1 when `byte` is not hex."""
    if byte >= UInt8(ord("0")) and byte <= UInt8(ord("9")):
        return Int(byte) - ord("0")
    if byte >= UInt8(ord("a")) and byte <= UInt8(ord("f")):
        return Int(byte) - ord("a") + 10
    if byte >= UInt8(ord("A")) and byte <= UInt8(ord("F")):
        return Int(byte) - ord("A") + 10
    return -1


def _parse_bytes(text: String) -> Array[UInt8, 16]:
    """Read the canonical text form into sixteen bytes.

    Assumes `_is_canonical(text)` already held, which every caller checks
    first, so no digit can fail to convert here.
    """
    var out = Array[UInt8, 16](fill=0)
    var bytes = text.as_bytes()
    var index = 0
    var position = 0
    while position < _UUID_TEXT_LENGTH:
        if position == 8 or position == 13 or position == 18 or position == 23:
            position += 1
            continue
        var high = _hex_digit(bytes[position])
        var low = _hex_digit(bytes[position + 1])
        out[index] = UInt8(high * 16 + low)
        index += 1
        position += 2
    return out^


def _is_canonical(text: String) -> Bool:
    """Report whether `text` is exactly the 36-character hyphenated form.

    Hex digits are accepted in either case. Hyphens must sit at byte offsets
    8, 13, 18 and 23 and nowhere else.
    """
    if text.byte_length() != _UUID_TEXT_LENGTH:
        return False
    var bytes = text.as_bytes()
    for position in range(_UUID_TEXT_LENGTH):
        var is_hyphen_slot = (
            position == 8 or position == 13 or position == 18 or position == 23
        )
        if is_hyphen_slot:
            if bytes[position] != _HYPHEN:
                return False
        elif _hex_digit(bytes[position]) < 0:
            return False
    return True


struct UUID(Copyable, Equatable, Movable, Writable):
    """A PostgreSQL `uuid` value, held as its sixteen raw bytes.

    Two `UUID` values are equal when all sixteen bytes match, and every
    `UUID` writes itself as lowercase canonical text regardless of the case
    it was parsed from.
    """

    var bytes: Array[UInt8, 16]
    """The sixteen bytes of the UUID, most significant first."""

    def __init__(out self, bytes: Array[UInt8, 16]):
        """Construct a `UUID` from sixteen raw bytes.

        Every 16-byte sequence is a valid `UUID` here, so nothing is checked:
        the version and variant bits are kept exactly as given.

        Args:
            bytes: The sixteen bytes of the UUID, most significant first.
        """
        self.bytes = bytes.copy()

    def __init__(out self, text: String) raises PgError:
        """Construct a `UUID` from canonical text written by the caller.

        Args:
            text: The 36-character `8-4-4-4-12` form, hex in either case.

        Raises:
            PgError: `PgErrorKind.USAGE` when `text` is not that form.
        """
        if not _is_canonical(text):
            raise _usage_error(text)
        self.bytes = _parse_bytes(text)

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Decode canonical text that came from the server.

        Accepts exactly what the checked constructor accepts; only the
        reported error differs, so a malformed `uuid` cell reads like every
        other decoding failure.

        Args:
            text: The 36-character `8-4-4-4-12` form, hex in either case.

        Returns:
            The decoded `UUID`.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not that form.
        """
        if not _is_canonical(text):
            raise _decode_error(text)
        return Self(_parse_bytes(text))

    def __eq__(self, other: Self) -> Bool:
        """Compare two UUIDs for equality.

        Args:
            other: The UUID to compare against.

        Returns:
            True if all sixteen bytes match.
        """
        for i in range(16):
            if self.bytes[i] != other.bytes[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        """Compare two UUIDs for inequality.

        Args:
            other: The UUID to compare against.

        Returns:
            True if any of the sixteen bytes differ.
        """
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        """Write the UUID as lowercase canonical `8-4-4-4-12` text.

        Args:
            writer: The writer receiving the 36-character text.
        """
        var out = String()
        for i in range(16):
            if i == 4 or i == 6 or i == 8 or i == 10:
                out += "-"
            var byte = Int(self.bytes[i])
            out += _LOWER_HEX[byte=byte >> 4]
            out += _LOWER_HEX[byte=byte & 0xF]
        writer.write(out)
