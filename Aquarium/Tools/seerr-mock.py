#!/usr/bin/env python3
"""A stand-in Seerr server for testing Aquarium's requests features.

It is NOT Seerr. It answers the parts of Seerr's API the apps use, in the
shapes Seerr 3.5.0's source and API description give them, and it signs users
in the way Seerr does: by Jellyfin Quick Connect (or a Jellyfin user name and
password) against the QA Jellyfin server. What is "in the library" is read
from that server, so a title's availability and its Jellyfin id are real.

    python3 -I Tools/seerr-mock.py            # 127.0.0.1:8197 -> QA Jellyfin on 8196
    python3 -I Tools/seerr-mock.py --csrf     # with Seerr's CSRF protection on

Test controls (not part of Seerr):
    POST /__test/reset        forget every request (sessions stay), Cache Images back on
    POST /__test/images/off   Cache Images off: settings say so, /imageproxy answers 404
    POST /__test/images/on    and back on
    POST /__test/discover/slow?seconds=<n>  every /discover row answers n seconds late (reset: 0)
    POST /__test/expire       forget every session (the apps must sign in again)
    POST /__test/approve/<n>  approve request n
    POST /__test/decline/<n>  decline request n
    POST /__test/request?user=<jellyfin name>&type=<movie|tv>&id=<tmdb>[&seasons=1,2]
                              make a request as a user who has signed in
    GET  /__test/state        requests, sessions and the calls seen
    GET  /__test/library      what the Jellyfin library holds, by "<kind>-<tmdb>"
"""

import argparse
import json
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QA_DIR = os.environ.get("AQUARIUM_QA_DIR", os.path.expanduser("~/Library/Application Support/AquariumQA"))

# Titles the QA library does not have, so there is something to ask for.
# Ids are TMDB's own.
EXTRA_MOVIES = [
    (603, "The Matrix", "1999-03-31", 136, "A hacker learns what the world really is."),
    (27205, "Inception", "2010-07-16", 148, "A thief who steals from dreams is given one last job."),
    (155, "The Dark Knight", "2008-07-18", 152, "Gotham's protector meets the Joker."),
    (13, "Forrest Gump", "1994-07-06", 142, "A man with a low IQ lives through decades of history."),
    (680, "Pulp Fiction", "1994-10-14", 154, "Stories of crime in Los Angeles, out of order."),
    (284052, "Doctor Strange", "2016-11-04", 115, "A surgeon finds another kind of medicine."),
]
EXTRA_SHOWS = [
    (1396, "Breaking Bad", "2008-01-20", 5, "A chemistry teacher changes careers."),
    (66732, "Stranger Things", "2016-07-15", 4, "A boy vanishes and a town finds out why."),
    (1399, "Game of Thrones", "2011-04-17", 8, "Noble families fight for a throne."),
]
# How many seasons TMDB lists for shows the QA library holds part of.
REAL_SEASONS = {19885: 4, 63639: 6, 1437: 1}
# One person, so a person page has something that isn't in the library.
PEOPLE = {71580: [("tv", 19885), ("movie", 284052), ("movie", 27205)]}
# One collection.
COLLECTIONS = {2344: ("The Matrix Collection", [603])}

def _png(width=40, height=60, rgb=(72, 60, 120)):
    """A plain poster-shaped picture, made here so no file has to ship."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    row = b"\x00" + bytes(rgb) * width
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))


PNG = _png()


class Jellyfin:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, path, method="GET", body=None, token=None, device="seerr-mock"):
        auth = 'MediaBrowser Client="Seerr", Device="Seerr", DeviceId="%s", Version="3.5.0"' % device
        if token:
            auth += ', Token="%s"' % token
        data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", auth)
        req.add_header("Accept", "application/json")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None


class State:
    def __init__(self, jellyfin, csrf):
        self.jf = jellyfin
        self.csrf = csrf
        # Seerr's Settings > General > Cache Images. Off, `/imageproxy`
        # answers 404, as the real server does.
        self.cache_images = True
        self.discover_delay = 0.0
        self.lock = threading.Lock()
        self.sessions = {}      # cookie -> seerr user id
        self.users = {}         # jellyfin user id -> user dict
        self.requests = []
        self.next_request = 1
        self.calls = []
        self.catalogue = {}     # (kind, tmdb) -> title dict
        self.library = {}       # (kind, tmdb) -> {"id": jellyfin id, "seasons": [numbers]}
        self.library_read = 0

    # -- the library, from Jellyfin ---------------------------------------

    def read_library(self, force=False):
        if not force and time.time() - self.library_read < 20:
            return
        try:
            items = self.jf.call(
                "/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=ProviderIds,Overview,PremiereDate",
                token=self.jf.token,
            )["Items"]
        except Exception:
            return
        library = {}
        for item in items:
            tmdb = next((v for k, v in (item.get("ProviderIds") or {}).items() if k.lower() == "tmdb"), None)
            if not tmdb or not str(tmdb).isdigit():
                continue
            kind = "movie" if item["Type"] == "Movie" else "tv"
            entry = {"id": item["Id"], "seasons": []}
            if kind == "tv":
                try:
                    seasons = self.jf.call("/Shows/%s/Seasons" % item["Id"], token=self.jf.token)["Items"]
                    entry["seasons"] = sorted(s["IndexNumber"] for s in seasons if s.get("IndexNumber"))
                except Exception:
                    pass
            key = (kind, int(tmdb))
            library[key] = entry
            if key not in self.catalogue:
                count = max(REAL_SEASONS.get(int(tmdb), 0), max(entry["seasons"] or [0]))
                self.catalogue[key] = make_title(
                    kind, int(tmdb), item.get("Name") or "", (item.get("PremiereDate") or "")[:10],
                    item.get("Overview") or "", seasons=count,
                )
        with self.lock:
            self.library = library
            self.library_read = time.time()


def make_title(kind, tmdb, name, date, overview, runtime=None, seasons=0):
    title = {
        "id": tmdb, "mediaType": kind, "overview": overview,
        "posterPath": "/poster-%s-%d.png" % (kind, tmdb), "backdropPath": "/backdrop-%s-%d.png" % (kind, tmdb),
        "voteAverage": 7.5, "genres": [{"id": 18, "name": "Drama"}],
        "credits": {"cast": [{"id": 71580, "name": "Benedict Cumberbatch", "character": "Lead"}]},
    }
    if kind == "movie":
        title.update({"title": name, "releaseDate": date, "runtime": runtime or 100})
    else:
        title.update({
            "name": name, "firstAirDate": date,
            "seasons": [
                {"id": tmdb * 100 + n, "seasonNumber": n, "name": "Season %d" % n, "episodeCount": 10,
                 "airDate": "%d-01-01" % (int(date[:4] or 2000) + n - 1)}
                for n in range(1, seasons + 1)
            ],
        })
    return title


def seed(state):
    for tmdb, name, date, runtime, overview in EXTRA_MOVIES:
        state.catalogue[("movie", tmdb)] = make_title("movie", tmdb, name, date, overview, runtime=runtime)
    for tmdb, name, date, seasons, overview in EXTRA_SHOWS:
        state.catalogue[("tv", tmdb)] = make_title("tv", tmdb, name, date, overview, seasons=seasons)


# -- what Seerr says about a title ------------------------------------------

def public_user(user):
    return {k: user[k] for k in ("id", "displayName", "username", "jellyfinUsername", "permissions", "jellyfinUserId", "userType")}


def media_info(state, kind, tmdb, with_requests=True):
    """Seerr's MediaInfo for a title, or None when it has never met it."""
    held = state.library.get((kind, tmdb))
    live = [r for r in state.requests if r["type"] == kind and r["tmdbId"] == tmdb and r["status"] in (1, 2)]
    if not held and not live and not any(r for r in state.requests if r["type"] == kind and r["tmdbId"] == tmdb):
        return None
    total = len(state.catalogue.get((kind, tmdb), {}).get("seasons", []))
    seasons = []
    status = 1
    if held:
        if kind == "movie" or (total and len(held["seasons"]) >= total):
            status = 5
        else:
            status = 4
        seasons = [{"seasonNumber": n, "status": 5} for n in held["seasons"]]
    for request in live:
        wanted = 3 if request["status"] == 2 else 2
        if status in (1,) or (status == 2 and wanted == 3):
            status = wanted
        for n in request["seasons"]:
            if not any(s["seasonNumber"] == n for s in seasons):
                seasons.append({"seasonNumber": n, "status": wanted})
    info = {
        "id": tmdb, "mediaType": kind, "tmdbId": tmdb, "status": status, "status4k": 1,
        "seasons": sorted(seasons, key=lambda s: s["seasonNumber"]),
    }
    if held:
        info["jellyfinMediaId"] = held["id"]
    if with_requests:
        info["requests"] = [request_json(state, r, nested=True) for r in state.requests
                            if r["type"] == kind and r["tmdbId"] == tmdb]
    return info


def request_json(state, request, nested=False):
    user = next((u for u in state.users.values() if u["id"] == request["userId"]), None)
    out = {
        "id": request["id"], "status": request["status"], "createdAt": request["createdAt"],
        "type": request["type"], "is4k": request["is4k"],
        "seasons": [{"id": request["id"] * 100 + n, "seasonNumber": n, "status": request["status"]} for n in request["seasons"]],
        "requestedBy": public_user(user) if user else None,
    }
    if not nested:
        out["media"] = media_info(state, request["type"], request["tmdbId"], with_requests=False)
    return out


def result_json(state, key, with_type=True):
    title = state.catalogue[key]
    out = {k: title[k] for k in ("id", "overview", "posterPath", "backdropPath", "voteAverage") if k in title}
    for k in ("title", "name", "releaseDate", "firstAirDate"):
        if k in title:
            out[k] = title[k]
    if with_type:
        out["mediaType"] = key[0]
    info = media_info(state, key[0], key[1], with_requests=False)
    if info:
        out["mediaInfo"] = info
    return out


def page(results):
    return {"page": 1, "totalPages": 1, "totalResults": len(results), "results": results}


# -- the server ---------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None  # set in main

    def log_message(self, *args):
        pass

    # plumbing

    def cookies(self):
        out = {}
        for part in (self.headers.get("Cookie") or "").split(";"):
            if "=" in part:
                name, value = part.strip().split("=", 1)
                out[name] = value
        return out

    def send_json(self, status, body, headers=()):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        if self.state.csrf and self.path.startswith("/api"):
            secret = self.cookies().get("_csrf") or secrets.token_urlsafe(18)
            self.send_header("Set-Cookie", "_csrf=%s; Path=/; HttpOnly; SameSite=Strict" % secret)
            self.send_header("Set-Cookie", "XSRF-TOKEN=%s; Path=/" % ("tok-" + secret))
        self.end_headers()
        self.wfile.write(data)

    def refuse(self, status, message):
        self.send_json(status, {"message": message})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def user(self):
        cookie = self.cookies().get("connect.sid")
        user_id = self.state.sessions.get(cookie)
        return next((u for u in self.state.users.values() if u["id"] == user_id), None)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        state = self.state
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        body = self.body() if method != "GET" else {}
        with state.lock:
            state.calls.append({"method": method, "path": path, "cookie": bool(self.cookies().get("connect.sid"))})
            del state.calls[:-400]

        if path.startswith("/imageproxy/"):
            if not state.cache_images:
                return self.refuse(404, "Image caching is disabled.")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG)))
            self.end_headers()
            self.wfile.write(PNG)
            return
        if path.startswith("/__test/"):
            return self.test_control(method, path)
        if not path.startswith("/api/v1"):
            return self.refuse(404, "Not found")
        path = path[len("/api/v1"):]

        if state.csrf and method != "GET":
            secret = self.cookies().get("_csrf")
            if not secret or self.headers.get("X-XSRF-TOKEN") != "tok-" + secret:
                return self.refuse(403, "invalid csrf token")

        # Open to anyone.
        if path == "/settings/public":
            return self.send_json(200, {
                "initialized": True, "applicationTitle": "Seerr (QA stand-in)", "mediaServerType": 2,
                "movie4kEnabled": False, "series4kEnabled": False, "partialRequestsEnabled": True,
                "cacheImages": state.cache_images, "mediaServerLogin": True, "localLogin": True,
            })
        if path == "/status":
            return self.send_json(200, {"version": "3.5.0-mock", "commitTag": "mock"})
        if path.startswith("/auth/"):
            return self.auth(method, path, query, body)

        user = self.user()
        if not user:
            return self.refuse(403, "You do not have permission to access this endpoint")
        state.read_library()

        if path == "/search":
            term = (query.get("query") or [""])[0].lower()
            hits = [result_json(state, key) for key, title in sorted(state.catalogue.items(), key=lambda kv: kv[0][1])
                    if term and term in (title.get("title") or title.get("name") or "").lower()]
            return self.send_json(200, page(hits))
        if path.startswith("/discover/"):
            if state.discover_delay:
                time.sleep(state.discover_delay)
            kinds = {"movies": "movie", "tv": "tv"}
            part = path.split("/")[2]
            keys = sorted(state.catalogue.keys(), key=lambda k: (k[1] * 7919) % 1009)
            if part in kinds:
                keys = [k for k in keys if k[0] == kinds[part]]
                if path.endswith("/upcoming"):
                    keys = list(reversed(keys))
                return self.send_json(200, page([result_json(state, k, with_type=False) for k in keys]))
            return self.send_json(200, page([result_json(state, k) for k in keys]))
        match = re.fullmatch(r"/(movie|tv)/(\d+)/(recommendations|similar)", path)
        if match:
            # Others of the same kind, in a fixed order. Real Seerr names each
            # entry's mediaType on both lists.
            kind, tmdb = match.group(1), int(match.group(2))
            if (kind, tmdb) not in state.catalogue:
                return self.refuse(404, "Unable to retrieve %s." % ("movie" if kind == "movie" else "series"))
            keys = sorted((k for k in state.catalogue if k[0] == kind and k[1] != tmdb), key=lambda k: (k[1] * 7919 + tmdb) % 1009)
            if match.group(3) == "similar":
                keys = list(reversed(keys))
            return self.send_json(200, page([result_json(state, k) for k in keys[:20]]))
        match = re.fullmatch(r"/(movie|tv)/(\d+)", path)
        if match:
            key = (match.group(1), int(match.group(2)))
            if key not in state.catalogue:
                return self.refuse(404, "Unable to retrieve %s." % ("movie" if key[0] == "movie" else "series"))
            title = dict(state.catalogue[key])
            info = media_info(state, *key)
            if info:
                title["mediaInfo"] = info
            return self.send_json(200, title)
        match = re.fullmatch(r"/collection/(\d+)", path)
        if match:
            found = COLLECTIONS.get(int(match.group(1)))
            if not found:
                return self.refuse(404, "Unable to retrieve collection.")
            parts = [result_json(state, ("movie", tmdb), with_type=False) for tmdb in found[1] if ("movie", tmdb) in state.catalogue]
            return self.send_json(200, {"id": int(match.group(1)), "name": found[0], "parts": parts})
        match = re.fullmatch(r"/person/(\d+)/combined_credits", path)
        if match:
            keys = [k for k in PEOPLE.get(int(match.group(1)), []) if k in state.catalogue]
            return self.send_json(200, {"cast": [result_json(state, k) for k in keys], "crew": []})
        match = re.fullmatch(r"/user/(\d+)/quota", path)
        if match:
            free = {"days": 7, "limit": 0, "used": 0, "remaining": 0, "restricted": False}
            return self.send_json(200, {"movie": free, "tv": free})
        if path == "/request" and method == "GET":
            mine = state.requests
            by = (query.get("requestedBy") or [None])[0]
            if by:
                mine = [r for r in mine if str(r["userId"]) == by]
            mine = sorted(mine, key=lambda r: -r["id"])
            return self.send_json(200, {
                "pageInfo": {"pages": 1, "pageSize": len(mine), "results": len(mine), "page": 1},
                "results": [request_json(state, r) for r in mine],
            })
        if path == "/request" and method == "POST":
            return self.make_request(user, body)
        match = re.fullmatch(r"/request/(\d+)", path)
        if match and method == "DELETE":
            request = next((r for r in state.requests if r["id"] == int(match.group(1))), None)
            if not request:
                return self.refuse(404, "Request not found.")
            if request["userId"] != user["id"] or request["status"] != 1:
                return self.refuse(401, "You do not have permission to delete this request.")
            state.requests.remove(request)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        return self.refuse(404, "Not found")

    def make_request(self, user, body):
        state = self.state
        kind, tmdb = body.get("mediaType"), body.get("mediaId")
        key = (kind, tmdb)
        if key not in state.catalogue:
            return self.refuse(404, "Unable to retrieve %s." % ("movie" if kind == "movie" else "series"))
        held = state.library.get(key)
        seasons = []
        if kind == "movie":
            if held or any(r for r in state.requests if r["type"] == kind and r["tmdbId"] == tmdb and r["status"] in (1, 2)):
                return self.refuse(409, "Request for this media already exists.")
        else:
            wanted = body.get("seasons")
            every = [s["seasonNumber"] for s in state.catalogue[key]["seasons"]]
            wanted = every if wanted in (None, "all") else [n for n in wanted if n in every]
            taken = set(held["seasons"] if held else [])
            for r in state.requests:
                if r["type"] == kind and r["tmdbId"] == tmdb and r["status"] in (1, 2):
                    taken.update(r["seasons"])
            seasons = [n for n in wanted if n not in taken]
            if not seasons:
                return self.send_json(202, {"message": "No seasons available to request"})
        request = {
            "id": state.next_request, "status": 1, "type": kind, "tmdbId": tmdb, "seasons": seasons,
            "is4k": bool(body.get("is4k")), "userId": user["id"],
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        }
        state.next_request += 1
        state.requests.append(request)
        return self.send_json(201, request_json(state, request))

    # signing in, the way Seerr does it

    def auth(self, method, path, query, body):
        state = self.state
        if path == "/auth/me":
            user = self.user()
            if not user:
                return self.refuse(403, "You do not have permission to access this endpoint")
            return self.send_json(200, public_user(user))
        if path == "/auth/logout" and method == "POST":
            state.sessions.pop(self.cookies().get("connect.sid"), None)
            return self.send_json(200, {"status": "ok"})
        try:
            if path == "/auth/jellyfin/quickconnect/initiate" and method == "POST":
                answer = state.jf.call("/QuickConnect/Initiate", method="POST")
                return self.send_json(200, {"code": answer["Code"], "secret": answer["Secret"]})
            if path == "/auth/jellyfin/quickconnect/check":
                secret = (query.get("secret") or [""])[0]
                if not re.fullmatch(r"[A-Fa-f0-9]{8,128}", secret):
                    return self.refuse(400, "Invalid secret format")
                answer = state.jf.call("/QuickConnect/Connect?secret=" + secret)
                return self.send_json(200, {"authenticated": bool(answer.get("Authenticated"))})
            if path == "/auth/jellyfin/quickconnect/authenticate" and method == "POST":
                secret = body.get("secret") or ""
                if not re.fullmatch(r"[A-Fa-f0-9]{8,128}", secret):
                    return self.refuse(400, "Secret required")
                answer = state.jf.call("/Users/AuthenticateWithQuickConnect", method="POST", body={"Secret": secret})
                return self.signed_in(answer)
            if path == "/auth/jellyfin" and method == "POST":
                if not body.get("username"):
                    return self.refuse(500, "You must provide an username")
                answer = state.jf.call(
                    "/Users/AuthenticateByName", method="POST",
                    body={"Username": body["username"], "Pw": body.get("password") or ""},
                )
                return self.signed_in(answer)
        except urllib.error.HTTPError as failure:
            if failure.code in (400, 401):
                return self.refuse(401, "INVALID_CREDENTIALS")
            return self.refuse(500, "Something went wrong.")
        except Exception:
            return self.refuse(500, "Something went wrong.")
        return self.refuse(404, "Not found")

    def signed_in(self, answer):
        state = self.state
        jf_user = answer["User"]
        with state.lock:
            user = state.users.get(jf_user["Id"])
            if not user:
                user = {
                    "id": len(state.users) + 1, "displayName": jf_user["Name"], "username": "",
                    "jellyfinUsername": jf_user["Name"], "jellyfinUserId": jf_user["Id"],
                    # REQUEST: may ask, needs approval.
                    "permissions": 32, "userType": 3,
                }
                state.users[jf_user["Id"]] = user
            cookie = "s%3A" + secrets.token_urlsafe(24)
            state.sessions[cookie] = user["id"]
        # The Jellyfin session Seerr was handed is not needed by a stand-in.
        try:
            state.jf.call("/Sessions/Logout", method="POST", token=answer.get("AccessToken"))
        except Exception:
            pass
        self.send_json(200, public_user(user), headers=[("Set-Cookie", "connect.sid=%s; Path=/; HttpOnly; SameSite=Lax" % cookie)])

    def test_control(self, method, path):
        state = self.state
        if path == "/__test/state":
            return self.send_json(200, {
                "requests": state.requests, "sessions": len(state.sessions),
                "users": list(state.users.values()), "calls": state.calls,
            })
        if path == "/__test/library":
            state.read_library(force=True)
            return self.send_json(200, {"%s-%d" % key: held for key, held in state.library.items()})
        if method != "POST":
            return self.refuse(405, "POST")
        if path == "/__test/request":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            name = (query.get("user") or [""])[0]
            user = next((u for u in state.users.values() if u["jellyfinUsername"] == name), None)
            if not user:
                return self.refuse(404, "No such user has signed in.")
            state.read_library()
            seasons = [int(n) for n in (query.get("seasons") or [""])[0].split(",") if n]
            return self.make_request(user, {
                "mediaType": (query.get("type") or ["movie"])[0], "mediaId": int((query.get("id") or ["0"])[0]),
                "seasons": seasons or None,
            })
        if path == "/__test/reset":
            state.requests = []
            state.calls = []
            state.cache_images = True
            state.discover_delay = 0.0
            state.read_library(force=True)
            return self.send_json(200, {"status": "ok"})
        if path == "/__test/discover/slow":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            state.discover_delay = float(query.get("seconds", ["0"])[0])
            return self.send_json(200, {"status": "ok"})
        if path in ("/__test/images/on", "/__test/images/off"):
            state.cache_images = path.endswith("/on")
            return self.send_json(200, {"status": "ok"})
        if path == "/__test/expire":
            state.sessions = {}
            return self.send_json(200, {"status": "ok"})
        match = re.fullmatch(r"/__test/(approve|decline)/(\d+)", path)
        if match:
            for request in state.requests:
                if request["id"] == int(match.group(2)):
                    request["status"] = 2 if match.group(1) == "approve" else 3
            return self.send_json(200, {"status": "ok"})
        return self.refuse(404, "Not found")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8197)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--jellyfin", default=os.environ.get("AQUARIUM_QA_SERVER", "http://127.0.0.1:8196"))
    parser.add_argument("--csrf", action="store_true", help="require Seerr's CSRF token on writes")
    args = parser.parse_args()
    token_file = os.path.join(QA_DIR, "admin.token")
    token = open(token_file).read().strip() if os.path.exists(token_file) else ""
    state = State(Jellyfin(args.jellyfin, token), args.csrf)
    seed(state)
    state.read_library(force=True)
    Handler.state = state
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("Seerr stand-in on http://%s:%d (Jellyfin %s, %d titles, %d in the library)" % (
        args.host, args.port, args.jellyfin, len(state.catalogue), len(state.library)), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
