"""Today's Mumbai edition of The Hindu e-paper as clean articles, for Rajeshwari's own subscription.

The e-paper is published as a package: an issue list, an index of every page and what sits on it
(articles, photos, ads), and each article as its own HTML page. This module:
- finds today's issue,
- walks the pages in print order and keeps the articles (ads, promos and empty boxes are dropped),
- joins "Continued on PAGE n" pieces back onto their story (the continuation is named "CONT <name>"),
- returns stories in the same shape build.py uses for RSS papers, with one photo each.

Personal use only: the resulting book is encrypted before it goes on the web (see seal.py).
"""
from __future__ import annotations

import concurrent.futures as cf
import datetime as dt
import html
import io
import json
import re
import sys
import urllib.parse
import urllib.request

import lxml.html

ROOT = "https://epaper.thehindu.com/ccidist-ws/th/{edition}/"
UA = {"User-Agent": "Mozilla/5.0 (personal Kindle edition)"}

# page groups as printed, with friendlier names
SECTION_NAMES = {
    "Front": "Front page", "Text": "Text & Context", "Edit": "Editorial & Opinion", "RglAdpage": "City",
    "SplSports": "Sport", "Sports": "Sport", "Back": "Back page",
}


def _get(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def _norm(name: str) -> str:
    name = re.sub(r"^\s*CONT\s+", "", name or "", flags=re.I)
    return re.sub(r"[^a-z0-9]+", "", name.lower())[:28]


def _text(el) -> str:
    return re.sub(r"\s+", " ", el.text_content()).strip() if el is not None else ""


def _parse_article(raw: str):
    doc = lxml.html.fromstring(raw)
    first = lambda xp: (doc.xpath(xp) or [None])[0]
    title = _text(first('//h1[contains(@class,"head")]'))
    deck = _text(first('//h2[contains(@class,"head_deck")]'))
    byline = _text(first('//span[contains(@class,"byline_name")]'))
    dateline = _text(first('//span[contains(@class,"dateline")]'))
    paras = []
    for p in doc.xpath('//div[contains(@class,"body")]//p'):
        t = _text(p)
        if not t or re.fullmatch(r"(?i)continued (on|from) page ?\d+\.?", t):
            continue
        t = re.sub(r"(?i)\s*continued on page ?\d+\.?$", "", t)
        sub = p.getparent() is not None and "subhead" in (p.getparent().get("class") or "")
        paras.append(("h3" if sub else "p", t))
    photo, caption = None, ""
    m = re.search(r"let galleryItems\s*=\s*(\[.*?\]);", raw, re.S)
    if m:
        try:
            items = json.loads(m.group(1))
            if items:
                photo = items[0].get("imageRef")
                caption = _text(lxml.html.fromstring(items[0].get("captionBody") or "<p></p>"))
        except Exception:
            pass
    return {"title": title, "deck": deck, "byline": byline, "dateline": dateline, "paras": paras,
            "photo": photo, "caption": caption}


def _photo(base: str, ref: str) -> bytes | None:
    """Fetch an article photo and make it small and grey for e-ink."""
    try:
        from PIL import Image, ImageOps
        raw = _get(base + urllib.parse.quote(ref.split("?")[0], safe="/+"))
        im = ImageOps.grayscale(Image.open(io.BytesIO(raw)))
        im.thumbnail((600, 600))
        out = io.BytesIO()
        im.save(out, "JPEG", quality=62, optimize=True)
        return out.getvalue()
    except Exception:
        return None


def todays_issue(edition: str, day: dt.date):
    """Issue id for `day` (title is dd-mm-yyyy), or None if it isn't out yet."""
    data = json.loads(_get(ROOT.format(edition=edition) + "issues/"))
    want = day.strftime("%d-%m-%Y")
    for it in data.get("issues", {}).get("web", []):
        if it.get("title") == want:
            return it["id"]
    return None


def collect(edition: str, day: dt.date):
    """Stories for today's edition, in print order. Empty list if the issue isn't published."""
    iid = todays_issue(edition, day)
    if not iid:
        print(f"  ! no {edition} issue for {day} yet", file=sys.stderr)
        return []
    base = ROOT.format(edition=edition) + f"issues/{iid}/OPS/"
    index = json.loads(_get(base + "cciobjects.json"))

    pieces = []  # (order, page no, section, page id, article object)
    for order, page in enumerate(index.get("children", [])):
        if page.get("kind") != "Page":
            continue
        pa = page.get("attributes", {})
        section = SECTION_NAMES.get(pa.get("PageGroup", ""), pa.get("PageGroup", "") or "News")
        for obj in page.get("children", []):
            if obj.get("kind") != "Article":
                continue  # ads, photos, graphics and stray text boxes
            pieces.append((order, pa.get("Page", ""), section, page["id"], obj))

    def fetch(piece):
        _o, _pg, _sec, pid, obj = piece
        try:
            raw = _get(base + f"{pid}%2B{obj['id']}.html").decode("utf-8", "replace")
            return _parse_article(raw)
        except Exception as e:
            print(f"  ! article {obj['id']}: {e}", file=sys.stderr)
            return None

    with cf.ThreadPoolExecutor(6) as ex:
        parsed = list(ex.map(fetch, pieces))

    stories, by_name = [], {}
    conts = []
    for piece, art in zip(pieces, parsed):
        if not art:
            continue
        _o, page_no, section, _pid, obj = piece
        name = obj.get("attributes", {}).get("Name", "")
        if re.match(r"\s*CONT\s", name, re.I):
            conts.append((name, art))
            continue
        words = sum(len(t.split()) for _k, t in art["paras"])
        if words < 40:
            continue  # promos, QR codes, captions-only boxes
        title = art["title"] or obj.get("attributes", {}).get("Headline", "") or art["paras"][0][1][:80]
        s = {"section": section, "title": title, "deck": art["deck"], "author": art["byline"],
             "dateline": art["dateline"], "page": page_no, "paras": art["paras"], "when": None, "link": "",
             "photo_ref": art["photo"], "caption": art["caption"]}
        stories.append(s)
        by_name.setdefault(_norm(name), s)

    joined = 0
    for name, art in conts:
        s = by_name.get(_norm(name))
        if s:
            s["paras"].extend(art["paras"])
            joined += 1
        elif sum(len(t.split()) for _k, t in art["paras"]) >= 40:  # orphan continuation: keep it on its own
            stories.append({"section": "News", "title": art["title"] or "(continued)", "deck": "", "author": "",
                            "dateline": "", "page": "", "paras": art["paras"], "when": None, "link": "",
                            "photo_ref": None, "caption": ""})

    # photos
    with cf.ThreadPoolExecutor(6) as ex:
        photos = list(ex.map(lambda s: _photo(base, s["photo_ref"]) if s["photo_ref"] else None, stories))

    for i, (s, ph) in enumerate(zip(stories, photos)):
        parts = []
        if s["deck"]:
            parts.append(f"<p class='deck'>{html.escape(s['deck'])}</p>")
        if ph:
            s["images"] = [(f"img/h{i}.jpg", ph)]
            cap = f"<p class='caption'>{html.escape(s['caption'])}</p>" if s["caption"] else ""
            parts.append(f"<div class='photo'><img src='img/h{i}.jpg' alt=''/>{cap}</div>")
        if s["dateline"]:
            parts.append(f"<p class='meta'>{html.escape(s['dateline'])}</p>")
        parts += [f"<{k}>{html.escape(t)}</{k}>" for k, t in s["paras"]]
        s["body"] = "".join(parts)
        s["teaser"] = (s["deck"] + " " + " ".join(t for _k, t in s["paras"]))[:320]
        if s["page"]:
            s["author"] = " · ".join(x for x in [s["author"], f"Page {s['page']}"] if x)
    print(f"  e-paper issue {iid}: {len(stories)} articles, {joined} continuations joined, "
          f"{sum(1 for p in photos if p)} photos")
    return stories


if __name__ == "__main__":
    st = collect(sys.argv[1] if len(sys.argv) > 1 else "th_mumbai", dt.date.today())
    for s in st[:12]:
        print(s["section"], "|", s["title"][:70], "|", len(s["paras"]), "paras")
