"""nftables through libnftables in this process, instead of starting an `nft` program for every call.

The agent reads its counters every second; starting `nft` each time costs far more CPU than the work
itself. libnftables is the library the nft program is built on (it ships with the nftables package),
so the commands and their output are exactly the same. If the library cannot be loaded, run() returns
None and the caller falls back to the nft program.
"""
import ctypes
import threading

JSON = 1 << 4          # NFT_CTX_OUTPUT_JSON
_lock = threading.Lock()
_ctx = {"lib": None, "ctx": None, "failed": False}


def _load():
    if _ctx["lib"] or _ctx["failed"]:
        return _ctx["lib"]
    try:
        lib = ctypes.CDLL("libnftables.so.1")
        lib.nft_ctx_new.restype = ctypes.c_void_p
        lib.nft_ctx_new.argtypes = [ctypes.c_uint32]
        for name in ("nft_ctx_buffer_output", "nft_ctx_buffer_error"):
            getattr(lib, name).argtypes = [ctypes.c_void_p]
        for name in ("nft_ctx_get_output_buffer", "nft_ctx_get_error_buffer"):
            getattr(lib, name).argtypes = [ctypes.c_void_p]
            getattr(lib, name).restype = ctypes.c_char_p
        lib.nft_ctx_output_set_flags.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        lib.nft_ctx_output_get_flags.argtypes = [ctypes.c_void_p]
        lib.nft_ctx_output_get_flags.restype = ctypes.c_uint
        lib.nft_run_cmd_from_buffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.nft_run_cmd_from_buffer.restype = ctypes.c_int
        ctx = lib.nft_ctx_new(0)
        if not ctx or lib.nft_ctx_buffer_output(ctx) or lib.nft_ctx_buffer_error(ctx):
            raise OSError("nft_ctx_new failed")
        _ctx.update(lib=lib, ctx=ctx, base=lib.nft_ctx_output_get_flags(ctx))
    except (OSError, AttributeError):
        _ctx["failed"] = True
    return _ctx["lib"]


def run(cmd, json_out=False):
    """(ok, output, error) for one nft command line, or None when the library is not available."""
    with _lock:
        lib = _load()
        if not lib:
            return None
        ctx = _ctx["ctx"]
        lib.nft_ctx_output_set_flags(ctx, _ctx["base"] | (JSON if json_out else 0))
        rc = lib.nft_run_cmd_from_buffer(ctx, cmd.encode())
        out = (lib.nft_ctx_get_output_buffer(ctx) or b"").decode("utf-8", "replace")
        err = (lib.nft_ctx_get_error_buffer(ctx) or b"").decode("utf-8", "replace")
        return rc == 0, out, err
