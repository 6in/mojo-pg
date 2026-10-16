"""Arbitrary-precision decimal mirroring PostgreSQL's `numeric`.

Holds `Decimal`, a value with the same four parts PostgreSQL keeps in a
`numeric`: a sign, a base-10000 weight, a display scale and a list of
base-10000 digit groups. Keeping the server's own representation means a
`numeric` survives a round trip unchanged -- including the trailing zeroes
that `"1.50"` carries and that no binary floating-point type can hold.

This module is a leaf: it imports only `pq.errors`, so both the text and the
binary decoder can depend on it.
"""

from pq.errors import PgError, PgErrorKind

comptime _MAX_DSCALE = 16383
comptime _CH_ZERO = UInt8(ord("0"))
comptime _CH_NINE = UInt8(ord("9"))
comptime _CH_DOT = UInt8(ord("."))
comptime _CH_PLUS = UInt8(ord("+"))
comptime _CH_MINUS = UInt8(ord("-"))


def _is_digit(byte: UInt8) -> Bool:
    """Return True when `byte` is one of the ASCII digits `0` to `9`."""
    return byte >= _CH_ZERO and byte <= _CH_NINE


def _pad4(value: Int) -> String:
    """Return `value` as exactly four decimal digits, zero padded."""
    var out = String()
    out += String(value // 1000)
    out += String((value // 100) % 10)
    out += String((value // 10) % 10)
    out += String(value % 10)
    return out^


def _usage_error(text: String) -> PgError:
    """Build the `USAGE` error for a literal the constructor rejects."""
    return PgError(
        PgErrorKind.USAGE,
        String('invalid numeric literal "', text, '"'),
    )


def _decode_error(text: String) -> PgError:
    """Build the `TYPE_MISMATCH` error for text that does not parse."""
    return PgError(
        PgErrorKind.TYPE_MISMATCH,
        String('cannot decode "', text, '" as numeric'),
    )


@fieldwise_init
struct Decimal(Copyable, Equatable, Movable, Writable):
    """An exact decimal number, shaped like a PostgreSQL `numeric`.

    The value of a finite `Decimal` is the sum of
    `_digits[i] * 10000 ** (_weight - i)`, negated when the sign is negative.
    `_dscale` is the number of fractional decimal places to print and carries
    no value information, so it is deliberately left out of `__eq__`.
    """

    var _sign: UInt16
    """One of the five `_SIGN_*` constants."""

    var _weight: Int16
    """Base-10000 exponent of the first group in `_digits`."""

    var _dscale: UInt16
    """Number of fractional decimal digits to display."""

    var _digits: List[Int16]
    """Base-10000 digit groups, most significant first."""

    comptime _SIGN_POS = UInt16(0x0000)
    """Sign of a finite non-negative value."""

    comptime _SIGN_NEG = UInt16(0x4000)
    """Sign of a finite negative value."""

    comptime _SIGN_NAN = UInt16(0xC000)
    """Sign marking the not-a-number value."""

    comptime _SIGN_PINF = UInt16(0xD000)
    """Sign marking positive infinity."""

    comptime _SIGN_NINF = UInt16(0xF000)
    """Sign marking negative infinity."""

    def __init__(out self, text: String) raises PgError:
        """Construct a `Decimal` from its decimal literal.

        The grammar accepted is `[+-]?(\\d+(\\.\\d*)?|\\.\\d+)` plus the three
        spellings `NaN`, `Infinity` and `-Infinity` (a leading `+` is allowed
        before `Infinity` too). Case matters, exponents are not accepted, and
        neither surrounding whitespace nor digit separators are tolerated.

        Args:
            text: The literal to read.

        Raises:
            PgError: `PgErrorKind.USAGE` when `text` is not such a literal,
                or when its fractional part has more than 16383 digits.
        """
        var parsed = Self._parse_opt(text)
        if not parsed:
            raise _usage_error(text)
        self = parsed.take()

    @staticmethod
    def parse(text: String) raises PgError -> Self:
        """Read a `Decimal` from wire text, as a decoder would.

        Accepts exactly what `__init__` accepts; only the error differs, so a
        value coming from the server reports a decoding failure rather than a
        caller mistake.

        Args:
            text: The literal to read.

        Returns:
            The value `text` spells.

        Raises:
            PgError: `PgErrorKind.TYPE_MISMATCH` when `text` is not a valid
                `numeric` literal.
        """
        var parsed = Self._parse_opt(text)
        if not parsed:
            raise _decode_error(text)
        return parsed.take()

    @staticmethod
    def _parse_opt(text: String) -> Optional[Self]:
        """Read `text` as a `numeric` literal, or return None if malformed.

        Follows PostgreSQL's `set_var_from_str`: the weight is derived from
        the position of the first significant digit, and the digits are then
        padded so that the first base-10000 group starts on a group boundary.
        Digits are collected one decimal place at a time and never folded
        into an integer, so an input of any length is safe.
        """
        if text == "NaN":
            return Self.nan()
        if text == "Infinity" or text == "+Infinity":
            return Self.infinity()
        if text == "-Infinity":
            return Self.negative_infinity()

        var b = text.as_bytes()
        var n = len(b)
        var i = 0
        var sign = Self._SIGN_POS
        if n > 0 and (b[0] == _CH_PLUS or b[0] == _CH_MINUS):
            if b[0] == _CH_MINUS:
                sign = Self._SIGN_NEG
            i = 1
        var int_start = i
        while i < n and _is_digit(b[i]):
            i += 1
        var int_end = i
        var frac_start = i
        var frac_end = i
        if i < n and b[i] == _CH_DOT:
            i += 1
            frac_start = i
            while i < n and _is_digit(b[i]):
                i += 1
            frac_end = i
        if i != n:
            return None
        var nfrac = frac_end - frac_start
        if int_end == int_start and nfrac == 0:
            return None
        if nfrac > _MAX_DSCALE:
            return None
        var dscale = UInt16(nfrac)

        # The significant digits, starting at the first non-zero one.
        var istrip = int_start
        while istrip < int_end and b[istrip] == _CH_ZERO:
            istrip += 1
        var sig = List[UInt8](capacity=(int_end - istrip) + nfrac + 1)
        var dweight: Int
        if istrip < int_end:
            dweight = (int_end - istrip) - 1
            for k in range(istrip, int_end):
                sig.append(b[k] - _CH_ZERO)
            for k in range(frac_start, frac_end):
                sig.append(b[k] - _CH_ZERO)
        else:
            var zeroes = 0
            while zeroes < nfrac and b[frac_start + zeroes] == _CH_ZERO:
                zeroes += 1
            if zeroes == nfrac:
                return Self._from_parts(
                    Self._SIGN_POS, 0, dscale, List[Int16]()
                )
            dweight = -zeroes - 1
            for k in range(frac_start + zeroes, frac_end):
                sig.append(b[k] - _CH_ZERO)

        var weight: Int
        if dweight >= 0:
            weight = (dweight + 4) // 4 - 1
        else:
            weight = -((-dweight - 1) // 4 + 1)
        if weight > 32767 or weight < -32768:
            return None
        var padding = (weight + 1) * 4 - (dweight + 1)
        var nsig = len(sig)
        var ngroups = (padding + nsig + 3) // 4
        var digits = List[Int16](capacity=ngroups)
        for g in range(ngroups):
            var group = 0
            for k in range(4):
                var pos = g * 4 + k - padding
                var digit = 0
                if pos >= 0 and pos < nsig:
                    digit = Int(sig[pos])
                group = group * 10 + digit
            digits.append(Int16(group))
        return Self._from_parts(sign, Int16(weight), dscale, digits^)

    @staticmethod
    def _from_parts(
        sign: UInt16, weight: Int16, dscale: UInt16, var digits: List[Int16]
    ) -> Self:
        """Build a `Decimal` from wire parts, normalizing them first.

        The package's decoders hand over exactly the four header fields a
        `numeric` carries on the wire. Normalization follows PostgreSQL's
        `strip_var`: leading zero groups go away (each one lowering the
        weight by one), trailing zero groups go away, and a value left with
        no groups becomes positive zero with weight 0. A special value keeps
        only its sign, since the server sends an arbitrary weight and dscale
        alongside `Infinity`.

        Args:
            sign: One of the five `_SIGN_*` constants.
            weight: Base-10000 exponent of the first group.
            dscale: Number of fractional decimal digits to display.
            digits: Base-10000 groups, most significant first.

        Returns:
            The normalized value.
        """
        if sign != Self._SIGN_POS and sign != Self._SIGN_NEG:
            return Self(sign, 0, 0, List[Int16]())
        var start = 0
        var end = len(digits)
        var stripped = Int(weight)
        while start < end and digits[start] == 0:
            start += 1
            stripped -= 1
        while end > start and digits[end - 1] == 0:
            end -= 1
        if start >= end:
            return Self(Self._SIGN_POS, 0, dscale, List[Int16]())
        var out = List[Int16](capacity=end - start)
        for k in range(start, end):
            out.append(digits[k])
        return Self(sign, Int16(stripped), dscale, out^)

    @staticmethod
    def nan() -> Self:
        """Return the `numeric` not-a-number value.

        Returns:
            The `NaN` value.
        """
        return Self(Self._SIGN_NAN, 0, 0, List[Int16]())

    @staticmethod
    def infinity() -> Self:
        """Return the `numeric` positive infinity.

        Returns:
            The `Infinity` value.
        """
        return Self(Self._SIGN_PINF, 0, 0, List[Int16]())

    @staticmethod
    def negative_infinity() -> Self:
        """Return the `numeric` negative infinity.

        Returns:
            The `-Infinity` value.
        """
        return Self(Self._SIGN_NINF, 0, 0, List[Int16]())

    def dscale(self) -> Int:
        """Return the number of fractional decimal digits displayed.

        Returns:
            The display scale, which is 0 for every special value.
        """
        return Int(self._dscale)

    def is_nan(self) -> Bool:
        """Report whether this is the not-a-number value.

        Returns:
            True for `NaN` only.
        """
        return self._sign == Self._SIGN_NAN

    def is_infinite(self) -> Bool:
        """Report whether this is one of the two infinities.

        Returns:
            True for `Infinity` and `-Infinity`.
        """
        return self._sign == Self._SIGN_PINF or self._sign == Self._SIGN_NINF

    def is_finite(self) -> Bool:
        """Report whether this is an ordinary number.

        Returns:
            True unless the value is `NaN`, `Infinity` or `-Infinity`.
        """
        return self._sign == Self._SIGN_POS or self._sign == Self._SIGN_NEG

    def __eq__(self, other: Self) -> Bool:
        """Compare two values for numeric equality.

        `_dscale` is display-only, so `1.0` and `1.00` are equal. `NaN`
        equals `NaN`, matching PostgreSQL's own `numeric` comparison rather
        than IEEE 754.

        Args:
            other: The value to compare against.

        Returns:
            True if both values have the same sign, weight and digits.
        """
        if self._sign != other._sign or self._weight != other._weight:
            return False
        if len(self._digits) != len(other._digits):
            return False
        for i in range(len(self._digits)):
            if self._digits[i] != other._digits[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        """Compare two values for numeric inequality.

        Args:
            other: The value to compare against.

        Returns:
            True if the values differ in sign, weight or digits.
        """
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        """Write the value in positional notation to `writer`.

        Mirrors PostgreSQL's `get_str_from_var`: never exponential, always
        exactly `dscale` fractional digits, and `NaN` / `Infinity` /
        `-Infinity` for the special values.

        Args:
            writer: The writer receiving the digits.
        """
        if self._sign == Self._SIGN_NAN:
            writer.write("NaN")
            return
        if self._sign == Self._SIGN_PINF:
            writer.write("Infinity")
            return
        if self._sign == Self._SIGN_NINF:
            writer.write("-Infinity")
            return
        if self._sign == Self._SIGN_NEG:
            writer.write("-")
        var ndigits = len(self._digits)
        var weight = Int(self._weight)
        if weight < 0:
            writer.write("0")
        else:
            for i in range(weight + 1):
                var group = Int(self._digits[i]) if i < ndigits else 0
                if i == 0:
                    writer.write(group)
                else:
                    writer.write(_pad4(group))
        var dscale = Int(self._dscale)
        if dscale > 0:
            writer.write(".")
            var frac = String()
            var g = weight + 1
            while frac.byte_length() < dscale:
                var group = 0
                if g >= 0 and g < ndigits:
                    group = Int(self._digits[g])
                frac += _pad4(group)
                g += 1
            writer.write(frac[byte=0:dscale])
