#!/usr/bin/env python3
"""Official Discogs OAuth1 read-only QA. Never log credentials, responses, identities or headers."""
import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import ssl
import sys
import time
from urllib.parse import quote, urlencode, urlsplit, parse_qsl

HOST = "api.discogs.com"
BASE = "https://" + HOST
RELEASES = (
    ("38012673", "Estiva", "Via Balearia", None),
    ("37332711", "Kyau & Albert x Maywave", "1000 Years", "Maywave"),
    ("36397609", "Matt Fax", "Only You", None),
    ("36819730", "Matt Fax", "Till You Let Go", None),
    ("35534398", "Quivver", "Consciousness EP", None),
)
REQUIRED = (
    "DISCOGS_OAUTH_CONSUMER_KEY",
    "DISCOGS_OAUTH_CONSUMER_SECRET",
    "DISCOGS_OAUTH_ACCESS_TOKEN",
    "DISCOGS_OAUTH_TOKEN_SECRET",
)


def escape(value):
    return quote(str(value), safe="~-._")


def authorization(method, url, consumer_key, consumer_secret, token, token_secret, nonce, stamp):
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.netloc != HOST or parts.fragment:
        raise ValueError("Refusing unapproved endpoint")
    oauth = {
        "oauth_consumer_key": consumer_key,
        "oauth_token": token,
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": str(stamp),
        "oauth_nonce": nonce,
        "oauth_version": "1.0",
    }
    pairs = list(parse_qsl(parts.query, keep_blank_values=True)) + list(oauth.items())
    normalized = "&".join(k + "=" + v for k, v in sorted((escape(k), escape(v)) for k, v in pairs))
    canonical_url = BASE + parts.path
    base_string = "&".join((escape(method.upper()), escape(canonical_url), escape(normalized)))
    key = (escape(consumer_secret) + "&" + escape(token_secret)).encode("ascii")
    signature = base64.b64encode(hmac.new(key, base_string.encode("ascii"), hashlib.sha1).digest()).decode("ascii")
    oauth["oauth_signature"] = signature
    return "OAuth " + ", ".join(escape(k) + '="' + escape(v) + '"' for k, v in sorted(oauth.items()))


def selftest():
    k = ("public-test-key", "synthetic-secret", "public-test-token", "synthetic-token-secret")
    url = BASE + "/database/search?artist=Kyau%20%26%20Albert&title=1000%20Years"
    a = authorization("GET", url, *k, "fixed-nonce", 100)
    b = authorization("GET", url, *k, "fixed-nonce", 100)
    assert a == b and a.startswith("OAuth oauth_consumer_key=")
    assert "synthetic-secret" not in a and "synthetic-token-secret" not in a
    assert a != authorization("GET", url, *k, "different-nonce", 100)
    try:
        authorization("GET", "https://attacker.invalid/", *k, "fixed-nonce", 100)
        raise AssertionError("Foreign OAuth host accepted")
    except ValueError:
        pass
    print("DISCOGS_CENTRAL_OAUTH_SELFTEST=PASS (synthetic credentials only)")


def request(path, credentials):
    if not (path == "/oauth/identity" or
            re.fullmatch(r"/releases/[1-9][0-9]{0,11}", path) or
            path.startswith("/database/search?")):
        raise ValueError("Unapproved Discogs API path")
    url = BASE + path
    signed = authorization("GET", url, *credentials, secrets.token_hex(20), int(time.time()))
    conn = http.client.HTTPSConnection(HOST, timeout=20, context=ssl.create_default_context())
    try:
        conn.request("GET", path, headers={
            "Authorization": signed,
            "User-Agent": "lxsdd-central-discogs-qa/1.0 (+https://github.com/lxsdd/dev-infrastructure-public)",
            "Accept": "application/vnd.discogs.v2+json",
        })
        response = conn.getresponse()
        data = response.read(1000001)
        if response.status != 200 or len(data) > 1000000:
            raise RuntimeError("Discogs API request unsuccessful")
        return json.loads(data)
    finally:
        conn.close()


def live():
    if (os.environ.get("GITHUB_ACTIONS") != "true" or
            os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or
            os.environ.get("GITHUB_REPOSITORY") != "lxsdd/dev-infrastructure-public" or
            os.environ.get("GITHUB_REF") != "refs/heads/main"):
        raise RuntimeError("Not running in the reviewed central security context")
    values = tuple(os.environ.get(name, "") for name in REQUIRED)
    if not all(re.fullmatch(r"[\x21-\x7e]{8,512}", v) for v in values):
        raise RuntimeError("Four required OAuth1 environment secrets are unavailable")
    identity = request("/oauth/identity", values)
    if not isinstance(identity, dict) or not isinstance(identity.get("id"), int):
        raise RuntimeError("OAuth1 identity endpoint did not return a valid identity")
    print("DISCOGS_CENTRAL_OAUTH_IDENTITY=PASS")

    found = 0
    for release_id, artist, title, partner in RELEASES:
        time.sleep(1.2)
        release = request("/releases/" + release_id, values)
        if (str(release.get("id")) != release_id or
                title.casefold() not in str(release.get("title", "")).casefold() or
                not release.get("artists") or not release.get("tracklist")):
            raise RuntimeError("Expected exact public release identity not confirmed")
        print("DISCOGS_CENTRAL_DIRECT_" + release_id + "=PASS")
        searches = [dict(artist=artist, title=title)]
        if partner:
            searches.append(dict(q='"' + partner + '"', title=title))
        searches.append(dict(q='"' + title + '"'))
        result = "NOT_FOUND"
        for index, query in enumerate(searches):
            time.sleep(1.2)
            query.update(type="release", per_page=100, page=1)
            path = "/database/search?" + urlencode(query)
            hits = request(path, values)
            if any(str(item.get("id")) == release_id and item.get("type") == "release"
                   for item in hits.get("results", [])):
                result = "EXACT" if index == 0 else "REVIEW_REQUIRED"
                break
        print("DISCOGS_CENTRAL_SEARCH_" + release_id + "=" + result)
        if result != "NOT_FOUND":
            found += 1
    if found != len(RELEASES):
        raise RuntimeError("Known release could not be found by bounded searches")
    print("DISCOGS_CENTRAL_OAUTH_LIVE=PASS: 5/5 (fallbacks require manual identity review)")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif len(sys.argv) == 1:
        try:
            live()
        except Exception:
            print("DISCOGS_CENTRAL_OAUTH_LIVE=FAIL (details intentionally suppressed)", file=sys.stderr)
            raise SystemExit(1)
    else:
        raise SystemExit("Expected --selftest or no arguments")
