"""Key mapping and keyboard input utilities for QEMU `sendkey`."""

import time

# Characters produced by pressing a key together with Shift, mapped to the
# unshifted key name that sendkey expects.
_SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right",
    ":": "semicolon", '"': "apostrophe",
    "<": "comma", ">": "dot", "?": "slash",
    "|": "backslash", "~": "grave_accent",
}

# Characters that map directly to a named (unshifted) key.
_DIRECT = {
    " ": "spc", "\t": "tab",
    "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right",
    ";": "semicolon", "'": "apostrophe",
    ",": "comma", ".": "dot", "/": "slash",
    "\\": "backslash", "`": "grave_accent",
}


def char_to_sendkey(ch):
    """Translate a single character into a QEMU sendkey argument."""
    if ch.isalpha() and ch.isascii():
        return f"shift-{ch.lower()}" if ch.isupper() else ch
    if ch.isdigit() and ch.isascii():
        return ch
    if ch in _DIRECT:
        return _DIRECT[ch]
    if ch in _SHIFTED:
        return f"shift-{_SHIFTED[ch]}"
    raise ValueError(f"unsupported character in command: {ch!r}")


def type_command(qmp, command, key_delay):
    """Simulate typing a string into the target guest followed by Return."""
    for ch in command:
        qmp.hmp(f"sendkey {char_to_sendkey(ch)}")
        time.sleep(key_delay)
    qmp.hmp("sendkey ret")
