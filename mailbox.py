"""Reads the Kindle's own Gmail inbox each morning (IMAP, with a Gmail app password).

- Substack newsletters become posts for the Substack digest.
- EPUB / PDF attachments become books, delivered to the Books folder on the Kindle and never cleared.

Needs two repository secrets: GMAIL_USER (the inbox address) and GMAIL_APP_PASSWORD.
Without them this quietly does nothing.
"""
from __future__ import annotations

import datetime as dt
import email
import email.policy
import imaplib
import os
import re
import sys
from email.utils import parseaddr, parsedate_to_datetime

BOOK_TYPES = (".epub", ".pdf", ".mobi", ".azw3", ".fb2", ".docx", ".txt", ".cbz")


def _connect():
    user, pw = os.environ.get("GMAIL_USER"), os.environ.get("GMAIL_APP_PASSWORD")
    if not user or not pw:
        return None
    try:
        box = imaplib.IMAP4_SSL("imap.gmail.com", 993)
        box.login(user, pw.replace(" ", ""))
        box.select('"[Gmail]/All Mail"', readonly=True)
        return box
    except Exception as e:
        print(f"  ! couldn't open the Kindle inbox: {e}", file=sys.stderr)
        return None


def _messages(box, since: dt.datetime):
    day = since.strftime("%d-%b-%Y")
    typ, data = box.search(None, f'(SINCE "{day}")')
    if typ != "OK":
        return
    for num in data[0].split():
        typ, raw = box.fetch(num, "(RFC822)")
        if typ != "OK" or not raw or not raw[0]:
            continue
        msg = email.message_from_bytes(raw[0][1], policy=email.policy.default)
        try:
            when = parsedate_to_datetime(msg["Date"])
        except Exception:
            when = None
        if when and when.tzinfo is None:
            when = when.replace(tzinfo=dt.timezone.utc)
        if when and when < since:
            continue
        yield msg, when


def _is_substack(msg) -> bool:
    sender = parseaddr(msg.get("From", ""))[1].lower()
    return sender.endswith("@substack.com") or "substack" in (msg.get("List-Id", "") + msg.get("List-Unsubscribe", "")).lower()


def _html_body(msg) -> str:
    part = msg.get_body(preferencelist=("html", "plain"))
    if not part:
        return ""
    text = part.get_content()
    if part.get_content_type() == "text/plain":
        text = "".join(f"<p>{line}</p>" for line in text.split("\n\n") if line.strip())
    return text


def _post_link(html: str) -> str:
    m = re.search(r'href="(https://[^"]+/p/[^"?#]+)', html)
    return m.group(1) if m else ""


def read_inbox(since: dt.datetime, areas_by_sub: dict, names_by_sub: dict):
    """Returns (substack_posts, books). Posts use the same shape as feed stories."""
    box = _connect()
    if not box:
        return [], []
    posts, books = [], []
    try:
        for msg, when in _messages(box, since):
            subject = str(msg.get("Subject", "")).strip() or "Untitled"
            if _is_substack(msg):
                name, addr = parseaddr(msg.get("From", ""))
                sub = addr.split("@")[0].lower()
                html = _html_body(msg)
                body = None
                try:
                    import trafilatura
                    body = trafilatura.extract(html, output_format="html", include_images=False, include_links=False)
                except Exception:
                    pass
                posts.append({
                    "section": names_by_sub.get(sub) or name or sub, "title": subject, "link": _post_link(html),
                    "author": name, "when": when, "body": body or html, "area": areas_by_sub.get(sub, ""),
                })
                continue
            for part in msg.iter_attachments():
                fname = part.get_filename() or ""
                if fname.lower().endswith(BOOK_TYPES):
                    data = part.get_payload(decode=True)
                    if data:
                        books.append({"name": re.sub(r'[\\/:*?"<>|]+', "-", fname), "data": data, "when": when,
                                      "from": parseaddr(msg.get("From", ""))[1]})
    finally:
        try:
            box.logout()
        except Exception:
            pass
    print(f"  inbox: {len(posts)} Substack emails, {len(books)} books")
    return posts, books
