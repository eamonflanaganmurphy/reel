# AMSMB2, patched for Reel

[AMSMB2](https://github.com/amosavian/AMSMB2) 4.0.3 (`1726aaa`, with libsmb2
at `aff9fa6`), copied here so Reel can carry a fix. Upstream's tests, CI and
build files are left out.

## Changes

**`AMSMB2/Context.swift`: close the socket when a request is given up on.**
`wait_for_reply` throws on a timeout (or a failed `poll`) but leaves the
request queued in libsmb2 with a callback pointer into the caller's stack
frame. When the reply turns up later, whoever services the socket next runs
the callback on whatever is there by then and crashes, typically the
disconnect in `SMB2Client.deinit`. Reel hit it when coming back from the
background: the echo `connectShare` sends on the old session timed out, the
client was replaced, and its deinit picked up the late echo reply
(`echo_cb` → `swift_retain` on a garbage pointer, `EXC_BAD_ACCESS`).
Now the socket is closed before the error is thrown, so the reply never
arrives, and the queued request is failed when the context is destroyed,
after the fd is marked invalid, which `generic_handler` ignores.

## Updating

Copy the new release over this folder (keeping this file and `Package.swift`'s
target list), then reapply the change above if upstream hasn't fixed it.
