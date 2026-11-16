#!/usr/bin/env python3
# A proxy in front of the QA server that a UI test can switch: cut the
# server, slow media down, or make some requests fail. The iPhone download,
# on-device music and offline tests sign the app in through it, so they can
# take "the server" away without touching the QA server or its 8098 proxy
# (both are shared with every other run on this Mac).
#
#   python3 -I Tools/qa-switch-proxy.py [--port 8177] [--control 8178] [--upstream 8196]
#
# 127.0.0.1:<port> forwards to 127.0.0.1:<upstream>. A test drives it with
# plain GETs on the control port (which stays up while the proxy is "down"):
#
#   /state                      what is set, as JSON (also: hits, pid)
#   /reset                      up, no cap, no failing, hits back to 0
#   /set?up=0                   stop listening and drop every connection,
#                               as if the process had been killed; up=1 undoes it
#   /set?rate=4000000           cap server-to-app bytes, in bits a second (0 = no cap) ...
#   /set?throttle=/Download     ... for requests whose first line contains this (empty = all)
#   /set?fail=/Download&status=410
#                               answer requests whose first line contains `fail`
#                               with that status; each one counts in `hits`
#
# Tools/run-tests.sh starts one for the iphone suite and stops it afterwards.
# It keeps no files and writes nothing unless --verbose.
import argparse, asyncio, json, os, sys, time
from urllib.parse import urlsplit, parse_qsl

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8177)
ap.add_argument("--control", type=int, default=0)
ap.add_argument("--upstream", type=int, default=8196)
ap.add_argument("--verbose", action="store_true")
args = ap.parse_args()
CONTROL = args.control or args.port + 1

state = {"up": True, "rate": 0.0, "throttle": "", "fail": "", "status": 410, "hits": 0}
listener = None
writers = set()
next_free = 0.0

def say(m):
    if args.verbose: print(time.strftime("%H:%M:%S"), m, file=sys.stderr, flush=True)

def is_request(d):
    return d[:4] in (b"GET ", b"POST", b"HEAD", b"DELE", b"PUT ", b"OPTI", b"PATC")

def first_line(d):
    return d.split(b"\r\n", 1)[0].decode("latin1", "replace")

async def take(n):
    # One queue for every capped connection: each chunk books its own time
    # on the line and waits for it. Nothing here can wait for ever, whatever
    # the rate (the QA folder's rproxy.py could, below about 2.6 Mbps).
    global next_free
    rate = state["rate"]
    if rate <= 0: return
    now = time.monotonic()
    start = max(now, next_free)
    next_free = start + n * 8 / rate
    if start > now: await asyncio.sleep(start - now)

async def handle(cr, cw):
    writers.add(cw)
    sw = None
    capped = [False]
    try:
        first = await cr.read(65536)
        if not first: return
        line = first_line(first)
        say(line[:160])

        def refuse(line):
            f = state["fail"]
            if f and f in line:
                state["hits"] += 1
                say(f"  -> {state['status']}")
                cw.write(f"HTTP/1.1 {state['status']} Refused By Test Proxy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
                return True
            return False

        if refuse(line):
            await cw.drain(); return
        capped[0] = state["throttle"] in line
        sr, sw = await asyncio.open_connection("127.0.0.1", args.upstream)
        writers.add(sw)
        sw.write(first); await sw.drain()

        async def up():
            try:
                while True:
                    d = await cr.read(65536)
                    if not d: break
                    if is_request(d):
                        line = first_line(d)
                        say(line[:160])
                        if refuse(line):
                            await cw.drain(); break
                        capped[0] = state["throttle"] in line
                    sw.write(d); await sw.drain()
            except Exception: pass
            finally:
                try: sw.close()
                except Exception: pass

        async def down():
            try:
                while True:
                    d = await sr.read(16384)
                    if not d: break
                    if capped[0]: await take(len(d))
                    cw.write(d); await cw.drain()
            except Exception: pass
            finally:
                try: cw.close()
                except Exception: pass

        await asyncio.gather(up(), down())
    except Exception:
        pass
    finally:
        for w in (cw, sw):
            if w is None: continue
            writers.discard(w)
            try: w.close()
            except Exception: pass

async def set_up(up):
    global listener
    if up and listener is None:
        listener = await asyncio.start_server(handle, "127.0.0.1", args.port)
        say(f"listening on {args.port}")
    elif not up and listener is not None:
        srv, listener = listener, None
        srv.close()
        for w in list(writers):
            try: w.transport.abort()
            except Exception: pass
        writers.clear()
        say("down")
    state["up"] = listener is not None

async def control(cr, cw):
    global next_free
    try:
        line = first_line(await cr.read(8192))
        parts = line.split(" ")
        url = urlsplit(parts[1] if len(parts) > 1 else "/")
        query = dict(parse_qsl(url.query, keep_blank_values=True))
        code = 200
        if url.path == "/reset":
            state.update(rate=0.0, throttle="", fail="", status=410, hits=0)
            next_free = 0.0
            await set_up(True)
        elif url.path == "/set":
            if "rate" in query: state["rate"] = float(query["rate"] or 0); next_free = 0.0
            if "throttle" in query: state["throttle"] = query["throttle"]
            if "fail" in query: state["fail"] = query["fail"]
            if "status" in query: state["status"] = int(query["status"])
            if "up" in query: await set_up(query["up"] not in ("0", "false", "no"))
        elif url.path != "/state":
            code = 404
        body = json.dumps(dict(state, pid=os.getpid(), port=args.port, upstream=args.upstream)).encode()
        cw.write(f"HTTP/1.1 {code} OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)
        await cw.drain()
    except Exception:
        pass
    finally:
        try: cw.close()
        except Exception: pass

async def main():
    await set_up(True)
    ctl = await asyncio.start_server(control, "127.0.0.1", CONTROL)
    say(f"control on {CONTROL}")
    await ctl.serve_forever()

try:
    asyncio.run(main())
except KeyboardInterrupt:
    pass
