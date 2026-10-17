"""Private platform layer: the OS calls `pq` needs beyond libpq itself.

`poll` is the only module here. It wraps `poll(2)` (`WSAPoll` on Windows) so
`AsyncConnection` can wait for a socket without pulling an event loop in.
Nothing in this package is re-exported from `pq`.
"""
