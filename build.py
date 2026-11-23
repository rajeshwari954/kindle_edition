"""Builds the morning editions for the Kindle.

For each paper in config.yaml: fetch its RSS sections, keep stories from the last
`lookback_hours`, pick the 5 that matter (Claude, if ANTHROPIC_API_KEY is set),
and write one EPUB with a cover, a "Today's summary" page and the sections.
Substacks become one digest EPUB. Everything lands in site/ with a today.json
manifest that the Kindle plugin reads.

Run:  python build.py            (writes ./site)
      python build.py --out DIR
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import html
import io
import json
import os
import re
import sys
import uuid
from pathlib import Path
from zoneinfo import ZoneInfo

import feedparser
import requests
import yaml
from ebooklib import epub
from PIL import Image, ImageDraw, ImageEnhance, ImageFont

ROOT = Path(__file__).parent
UA = "Mozilla/5.0 (X11; Linux x86_64) KindleDailyReads/1.0"
W, H = 758, 1024  # Paperwhite 2 screen


# ---------------------------------------------------------------- fetching

def fetch_feed(url: str):
    try:
        r = requests.get(url, headers={"User-Agent": UA}, timeout=25)
        r.raise_for_status()
        return feedparser.parse(r.content)
    except Exception as e:  # one bad feed must not sink the edition
        print(f"  ! feed failed {url}: {e}", file=sys.stderr)
        return feedparser.parse(b"")


def entry_time(e) -> dt.datetime | None:
    for k in ("published_parsed", "updated_parsed"):
        t = e.get(k)
        if t:
            return dt.datetime(*t[:6], tzinfo=dt.timezone.utc)
    return None


def clean_html(raw: str) -> str:
    """Keep simple, e-ink friendly markup only."""
    raw = re.sub(r"(?is)<(script|style|iframe|figure|noscript|form|button|svg)[^>]*>.*?</\1>", "", raw or "")
    raw = re.sub(r"(?is)<img[^>]*>", "", raw)
    raw = re.sub(r"(?i)<(/?)(div|section|article|span)[^>]*>", lambda m: "" if m.group(2).lower() == "span" else f"<{m.group(1)}p>", raw)
    raw = re.sub(r"(?i)\s(class|style|id|data-[\w-]+|onclick)=\"[^\"]*\"", "", raw)
    raw = re.sub(r"(<p>\s*</p>\s*)+", "", raw)
    return raw.strip()


def text_of(raw: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", raw or ""))).strip()


def full_text(url: str) -> str | None:
    """Pull the article body when the feed only gives a teaser."""
    try:
        import trafilatura
        r = requests.get(url, headers={"User-Agent": UA}, timeout=20)
        if r.status_code != 200:
            return None
        out = trafilatura.extract(r.text, output_format="html", include_images=False, include_links=False, favor_precision=True)
        return out
    except Exception:
        return None


def collect(sections, per_section, since, fetch_full=True):
    seen, stories = set(), []
    for sec in sections:
        feed = fetch_feed(sec["url"])
        kept = 0
        for e in feed.entries:
            link = e.get("link", "")
            key = link.split("?")[0] or e.get("title")
            when = entry_time(e)
            if key in seen or (when and when < since):
                continue
            seen.add(key)
            body = ""
            if e.get("content"):
                body = e.content[0].get("value", "")
            body = body or e.get("summary", "")
            stories.append({
                "section": sec["name"], "title": text_of(e.get("title", "Untitled")), "link": link,
                "author": e.get("author", ""), "when": when, "body": body,
            })
            kept += 1
            if kept >= per_section:
                break
    if fetch_full:
        short = [s for s in stories if len(text_of(s["body"])) < 700 and s["link"]]
        with cf.ThreadPoolExecutor(8) as ex:
            for s, got in zip(short, ex.map(lambda s: full_text(s["link"]), short)):
                if got and len(text_of(got)) > len(text_of(s["body"])):
                    s["body"] = got
    for s in stories:
        s["body"] = clean_html(s["body"]) or "<p>Open the full story online.</p>"
        s["teaser"] = text_of(s["body"])[:320]
    return stories


def substack_follows(subs, model):
    """Every publication the profile subscribes to, as feed entries."""
    profile = subs.get("profile")
    if not profile:
        return []
    try:
        r = requests.get(f"https://substack.com/api/v1/user/{profile}/public_profile", headers={"User-Agent": UA}, timeout=25)
        r.raise_for_status()
        data = r.json()
    except Exception as e:
        # Substack doesn't always answer cloud servers; use the saved list in config.yaml instead
        print(f"  ! couldn't read Substack follows for {profile} ({e}); using the saved list", file=sys.stderr)
        names = subs.get("names") or {}
        skip = set(subs.get("exclude") or [])
        return [{"name": names.get(sub, sub), "url": f"https://{sub}.substack.com/feed", "sub": sub, "area": area}
                for sub, area in (subs.get("areas") or {}).items() if sub not in skip]
    exclude = set(subs.get("exclude") or [])
    areas = subs.get("areas") or {}
    out = []
    for item in data.get("subscriptions") or []:
        pub = item.get("publication") or item
        sub = pub.get("subdomain")
        if not sub or sub in exclude:
            continue
        url = f"https://{sub}.substack.com/feed"  # redirects to a custom domain when there is one
        out.append({"name": pub.get("name") or sub, "url": url, "sub": sub, "area": areas.get(sub)})
    new = [f for f in out if not f["area"]]
    if new:
        guessed = classify_areas(new, model)
        for f in new:
            f["area"] = guessed.get(f["sub"]) or subs.get("default_area", "Current Affairs")
            print(f"  + new Substack {f['name']} → {f['area']}")
    return out


AREAS = ["Finance & Economics", "Geopolitics & History", "Current Affairs", "Case Laws & Judgements",
         "Health Sciences", "Philosophy & Psychology"]


def classify_areas(feeds, model):
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return {}
    listing = "\n".join(f"{f['sub']}: {f['name']}" for f in feeds)
    prompt = (f"Assign each newsletter to one reading area from {AREAS}. "
              'Reply with JSON only: {"subdomain": "area", ...}\n\n' + listing)
    try:
        import anthropic
        msg = anthropic.Anthropic(api_key=key).messages.create(model=model, max_tokens=800, thinking={"type": "disabled"},
                                                                 messages=[{"role": "user", "content": prompt}])
        txt = "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
        got = json.loads(re.search(r"\{.*\}", txt, re.S).group(0))
        return {k: v for k, v in got.items() if v in AREAS}
    except Exception as e:
        print(f"  ! area guess failed: {e}", file=sys.stderr)
        return {}


# ---------------------------------------------------------------- summary

def pick_highlights(paper, stories, model):
    """Return 5 dicts: {i, tag, why}. Claude if available, else the first stories."""
    tags = paper.get("tags") or []
    fallback = [{"i": i, "tag": s["section"], "why": s["teaser"][:150].rsplit(" ", 1)[0] + "…"} for i, s in enumerate(stories[:5])]
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key or not stories:
        return fallback
    listing = "\n".join(f"[{i}] ({s['section']}) {s['title']} — {s['teaser'][:220]}" for i, s in enumerate(stories[:80]))
    prompt = (
        f"These are today's stories from {paper['name']}. Pick the 5 that matter most for a reader in Mumbai "
        f"who is a law student and interns at a litigation firm. {paper.get('focus', '')}\n"
        f"Avoid near-duplicates, celebrity gossip and live blogs. For each, give a tag from {tags} "
        "and one plain sentence (max 22 words) on what happened and why it matters.\n"
        'Reply with JSON only: {"picks":[{"i":0,"tag":"...","why":"..."}]}\n\n' + listing
    )
    try:
        import anthropic
        msg = anthropic.Anthropic(api_key=key).messages.create(
            model=model, max_tokens=2500, thinking={"type": "disabled"}, messages=[{"role": "user", "content": prompt}])
        txt = "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
        m = re.search(r"\{.*\}", txt, re.S)
        if not m:
            raise ValueError(f"no JSON (stop={msg.stop_reason}, blocks={[b.type for b in msg.content]}): {txt[:300]!r}")
        picks = json.loads(m.group(0))["picks"]
        picks = [p for p in picks if isinstance(p.get("i"), int) and 0 <= p["i"] < len(stories)][:5]
        return picks or fallback
    except Exception as e:
        print(f"  ! summary failed for {paper['name']}: {e}", file=sys.stderr)
        return fallback


def summarize_posts(posts, model):
    """One plain sentence per post. Claude if available, else the post's first sentence."""
    def first_sentence(t):
        m = re.match(r"(.{40,200}?[.!?])\s", t + " ")
        return (m.group(1) if m else t[:150].rsplit(" ", 1)[0] + "…")
    out = [first_sentence(p["teaser"]) for p in posts]
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key or not posts:
        return out
    listing = "\n\n".join(f"[{i}] {p['title']} ({p['section']})\n{text_of(p['body'])[:1500]}" for i, p in enumerate(posts))
    prompt = ("Summarise each newsletter post below in one plain sentence of at most 22 words: the main point, "
              "not a teaser. Reply with JSON only: {\"s\":[\"...\", ...]} in the same order.\n\n" + listing)
    try:
        import anthropic
        msg = anthropic.Anthropic(api_key=key).messages.create(model=model, max_tokens=3000, thinking={"type": "disabled"}, messages=[{"role": "user", "content": prompt}])
        txt = "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
        got = json.loads(re.search(r"\{.*\}", txt, re.S).group(0))["s"]
        return [g if isinstance(g, str) and g.strip() else o for g, o in zip(got + [None] * len(out), out)][:len(out)]
    except Exception as e:
        print(f"  ! substack summaries failed: {e}", file=sys.stderr)
        return out


# ---------------------------------------------------------------- cover

def font(kind, size):
    candidates = {
        "serif": [ROOT / "fonts/Marcellus-Regular.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"],
        "sans": [ROOT / "fonts/DMSans.ttf", "/usr/share/fonts/truetype/google-fonts/ofl/dmsans/DMSans[opsz,wght].ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"],
        "bold": [ROOT / "fonts/DMSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"],
    }[kind]
    for c in candidates:
        if Path(c).exists():
            f = ImageFont.truetype(str(c), size)
            if kind == "bold":
                try:
                    f.set_variation_by_axes([14, 700])
                except Exception:
                    pass
            return f
    return ImageFont.load_default()


def wrap(draw, text, fnt, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=fnt) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def make_cover(name, subtitle, date_label, headlines, texture, panel_title="Today's summary") -> bytes:
    """Greyscale cover: the user's texture, a white panel, the name set in Marcellus.
    The paper's real logo is never reproduced."""
    tex_path = ROOT / "assets" / f"{texture}.jpg"
    if tex_path.exists():
        bg = Image.open(tex_path).convert("L")
        bg = bg.resize((W, int(bg.height * W / bg.width))) if bg.width < W else bg
        bg = bg.crop((0, 0, W, H)) if bg.height >= H else bg.resize((W, H))
        bg = ImageEnhance.Brightness(bg).enhance(0.55)
    else:
        bg = Image.new("L", (W, H), 60)
    im = bg.convert("L")
    d = ImageDraw.Draw(im)
    pad = 44
    # masthead
    d.rounded_rectangle((pad, 70, W - pad, 330), radius=34, fill=255)
    f_name = font("serif", 76)
    lines = wrap(d, name, f_name, W - 2 * pad - 60)
    if len(lines) > 2:
        f_name = font("serif", 58)
        lines = wrap(d, name, f_name, W - 2 * pad - 60)
    y = 100 if len(lines) > 1 else 135
    for ln in lines:
        d.text((W / 2, y), ln, font=f_name, fill=17, anchor="ma")
        y += f_name.size + 8
    d.line((pad + 60, 262, W - pad - 60, 262), fill=17, width=2)
    d.text((W / 2, 280), f"{subtitle}  ·  {date_label}", font=font("sans", 24), fill=40, anchor="ma")
    # today's summary on the cover
    d.rounded_rectangle((pad, 368, W - pad, H - 70), radius=34, fill=245)
    d.text((pad + 34, 396), panel_title, font=font("serif", 40), fill=17)
    y, f_h = 462, font("serif", 27)
    for n, h in enumerate(headlines[:5], 1):
        d.ellipse((pad + 34, y + 2, pad + 70, y + 38), fill=17)
        d.text((pad + 52, y + 20), str(n), font=font("bold", 20), fill=255, anchor="mm")
        hl = wrap(d, h, f_h, W - 2 * pad - 130)
        if len(hl) > 2:
            hl = [hl[0], hl[1].rstrip(",;:") + "…"]
        for k, ln in enumerate(hl):
            d.text((pad + 90, y + k * 34), ln, font=f_h, fill=17)
        y += len(hl) * 34 + 30
        if y > H - 140:
            break
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=88)
    return buf.getvalue()


def make_digest_cover(date_label, posts) -> bytes:
    """Substack digest cover in the self.v2 dashboard style: soft lace page, Marcellus title,
    rounded white cards with the post title, a one-line summary and the Substack's name."""
    bg_path = ROOT / "assets" / "lace_soft.jpg"
    if bg_path.exists():
        bg = Image.open(bg_path).convert("L")
        sc = max(W / bg.width, H / bg.height)
        bg = bg.resize((int(bg.width * sc) + 1, int(bg.height * sc) + 1)).crop((0, 0, W, H))
    else:
        bg = Image.new("L", (W, H), 239)
    im = bg.convert("RGBA")
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    pad = 34
    # header
    d.text((pad, 46), "SUBSTACK DIGEST", font=font("bold", 15), fill=(68, 68, 68, 255))
    d.text((pad, 70), "Substacks", font=font("serif", 54), fill=(17, 17, 17, 255))
    n = len(posts)
    d.text((pad, 138), f"{n} new post{'s' if n != 1 else ''}  ·  {date_label}", font=font("sans", 19), fill=(68, 68, 68, 255))
    # cards
    y, f_t, f_s, f_m = 196, font("serif", 23), font("sans", 16), font("bold", 13)
    inner = W - 2 * pad - 40
    shown = 0
    for p in posts:
        tl = wrap(d, p["title"], f_t, inner)[:2]
        sl = wrap(d, p.get("summary", ""), f_s, inner)
        if len(sl) > 2:
            sl = [sl[0], sl[1].rstrip(",;:") + "…"]
        h = 20 + len(tl) * 29 + 6 + len(sl) * 22 + 12 + 26 + 18
        if y + h > H - 70:
            break
        d.rounded_rectangle((pad, y, W - pad, y + h), radius=24, fill=(255, 255, 255, 222))
        ty = y + 20
        for ln in tl:
            d.text((pad + 20, ty), ln, font=f_t, fill=(17, 17, 17, 255)); ty += 29
        ty += 6
        for ln in sl:
            d.text((pad + 20, ty), ln, font=f_s, fill=(70, 70, 70, 255)); ty += 22
        ty += 12
        meta = f"{p['section']}  ·  {p.get('mins', 1)} min"
        mw = d.textlength(meta, font=f_m)
        d.rounded_rectangle((pad + 20, ty, pad + 20 + mw + 22, ty + 26), radius=13, fill=(230, 230, 230, 255))
        d.text((pad + 31, ty + 13), meta, font=f_m, fill=(17, 17, 17, 255), anchor="lm")
        y += h + 12
        shown += 1
    if shown < n:
        d.text((W / 2, H - 52), f"+ {n - shown} more inside", font=font("bold", 16), fill=(17, 17, 17, 255), anchor="mm")
    im = Image.alpha_composite(im, ov)
    folder = ROOT / "assets" / "folder_fawn.png"
    if folder.exists():
        f = Image.open(folder).convert("RGBA")
        f = f.resize((120, int(f.height * 120 / f.width))).rotate(6, expand=True, resample=Image.BICUBIC)
        im.alpha_composite(f, (W - pad - f.width, 42))
    buf = io.BytesIO()
    im.convert("L").save(buf, "JPEG", quality=88)
    return buf.getvalue()


# ---------------------------------------------------------------- epub

CSS = """
body{font-family:serif;line-height:1.45;margin:0 4%}
h1,h2{font-weight:normal;line-height:1.15}
h1{font-size:1.7em;margin:.6em 0 .3em}
h2{font-size:1.25em;margin:1.2em 0 .2em}
.meta{font-family:sans-serif;font-size:.8em;color:#444;margin:0 0 1em}
.pick{margin:0 0 1.1em}
.pick .tag{font-family:sans-serif;font-size:.75em;font-weight:bold;border:1px solid #111;border-radius:8px;padding:0 .35em}
.pick p{margin:.2em 0 0}
.toc a{text-decoration:none;color:#111}
.short{font-family:sans-serif;font-size:.85em;border-left:3px solid #111;padding:.2em 0 .2em .7em;margin:0 0 1.2em}
hr{border:0;border-top:1px solid #999;margin:1.4em 0}
"""


def esc(s):
    return html.escape(s or "", quote=True)


def write_epub(path: Path, title, author, date_label, cover, picks, stories, area, summary_title="Today's summary"):
    book = epub.EpubBook()
    book.set_identifier(str(uuid.uuid4()))
    book.set_title(f"{title} · {date_label}")
    book.set_language("en")
    book.add_author(author)
    book.add_metadata("DC", "subject", area)  # so the Kindle sync can file it in the Reading Log
    book.set_cover("cover.jpg", cover)
    cover_page = book.get_item_with_id("cover")
    if cover_page is not None:
        cover_page.is_linear = True  # a normal first page, so article positions count from it
    css = epub.EpubItem(uid="css", file_name="style.css", media_type="text/css", content=CSS)
    book.add_item(css)

    by_section: dict[str, list[int]] = {}
    for i, s in enumerate(stories):
        by_section.setdefault(s["section"], []).append(i)

    chapters, spine = [], ["cover"]
    frags = {}
    summary = epub.EpubHtml(title=summary_title, file_name="summary.xhtml")
    rows = []
    for n, p in enumerate(picks, 1):
        s = stories[p["i"]]
        rows.append(f'<div class="pick"><h2>{n}. <a href="s{p["i"]}.xhtml">{esc(s["title"])}</a></h2>'
                    f'<p><span class="tag">{esc(p.get("tag", s["section"]))}</span> {esc(p.get("why", ""))}</p></div>')
    summary.content = f"<h1>{esc(summary_title)}</h1><p class='meta'>{esc(title)} · {esc(date_label)}</p>{''.join(rows)}"
    summary.add_item(css)
    book.add_item(summary)
    spine.append(summary)
    toc = [summary]

    for sec, idxs in by_section.items():
        sec_items = []
        for i in idxs:
            s = stories[i]
            c = epub.EpubHtml(title=s["title"], file_name=f"s{i}.xhtml")
            meta = " · ".join(x for x in [sec, s["author"], s["when"].astimezone(ZoneInfo("Asia/Kolkata")).strftime("%a %d %b, %H:%M") if s["when"] else ""] if x)
            short = f"<p class='short'><b>In short:</b> {esc(s['summary'])}</p>" if s.get("summary") else ""
            c.content = (f"<h1>{esc(s['title'])}</h1><p class='meta'>{esc(meta)}</p>{short}{s['body']}"
                         f"<hr/><p class='meta'>Source: {esc(s['link'])}</p>")
            c.add_item(css)
            book.add_item(c)
            spine.append(c)
            frags[i] = len(spine)  # 1-based DocFragment index KOReader uses to jump here
            sec_items.append(c)
        toc.append((epub.Section(sec), sec_items))

    book.toc = toc
    book.spine = spine
    book.add_item(epub.EpubNcx())
    book.add_item(epub.EpubNav())
    path.parent.mkdir(parents=True, exist_ok=True)
    epub.write_epub(str(path), book)
    return frags


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="site")
    ap.add_argument("--no-full-text", action="store_true")
    args = ap.parse_args()

    cfg = yaml.safe_load((ROOT / "config.yaml").read_text())
    tz = ZoneInfo(cfg.get("timezone", "Asia/Kolkata"))
    now = dt.datetime.now(tz)
    since = now - dt.timedelta(hours=cfg.get("lookback_hours", 26))
    date_id = now.strftime("%Y-%m-%d")
    date_label = now.strftime("%a %d %b").replace(" 0", " ")
    out = Path(args.out)
    ed_dir = out / "editions" / date_id
    manifest = {"date": date_id, "label": date_label, "built": now.isoformat(timespec="minutes"), "files": []}

    for paper in cfg.get("papers", []):
        print(f"• {paper['name']}")
        stories = collect(paper["sections"], paper.get("per_section", 8), since, not args.no_full_text)
        if not stories:
            print("  (no stories, skipped)")
            continue
        picks = pick_highlights(paper, stories, cfg.get("summary_model", "claude-haiku-5-5"))
        cover = make_cover(paper["name"], paper.get("subtitle", ""), date_label, [stories[p["i"]]["title"] for p in picks], paper.get("texture", "lace"))
        fname = f"{date_id} {paper['name']}.epub"
        frags = write_epub(ed_dir / fname, paper["name"], paper["name"], date_label, cover, picks, stories, "Current Affairs")
        manifest["files"].append({
            "id": paper["id"], "kind": "paper", "name": paper["name"], "file": fname,
            "url": f"editions/{date_id}/{fname}", "count": len(stories), "area": "Current Affairs",
            "highlights": [{"title": stories[p["i"]]["title"], "tag": p.get("tag", ""), "why": p.get("why", ""),
                            "frag": frags.get(p["i"])} for p in picks],
        })
        print(f"  {len(stories)} stories")
        for p in picks:
            print(f"    · [{p.get('tag', '')}] {stories[p['i']]['title'][:90]} — {p.get('why', '')}")

    subs = (cfg.get("substacks") or {})
    feeds = substack_follows(subs, cfg.get("summary_model", "claude-haiku-5-5")) + (subs.get("feeds") or [])
    following = [{"name": f["name"], "area": f.get("area", "")} for f in feeds]

    # the Kindle's own Gmail inbox: Substack emails + books sent as attachments
    import mailbox
    book_window = now - dt.timedelta(days=7)
    mail_posts, books = mailbox.read_inbox(book_window, subs.get("areas") or {}, subs.get("names") or {})
    for p in mail_posts:
        p["body"] = clean_html(p["body"]) or "<p>Open the post online.</p>"
        p["teaser"] = text_of(p["body"])[:320]
        if not p.get("area"):
            p["area"] = subs.get("default_area", "Current Affairs")

    if feeds or mail_posts:
        print("• Substacks")
        posts = []
        for f in feeds:
            got = collect([{"name": f["name"], "url": f["url"]}], 10, since, fetch_full=False)
            for p in got:
                p["area"] = f.get("area", "")
            posts += got
        seen_titles = {p["title"].lower() for p in posts}
        for p in mail_posts:
            if (p["when"] is None or p["when"] >= since) and p["title"].lower() not in seen_titles:
                posts.append(p)
                seen_titles.add(p["title"].lower())
        if posts:
            for p, summ in zip(posts, summarize_posts(posts, cfg.get("summary_model", "claude-haiku-5-5"))):
                p["mins"] = max(1, round(len(text_of(p["body"]).split()) / 230))
                p["summary"] = summ
            picks = [{"i": i, "tag": f'{p["section"]} · {p["mins"]} min', "why": p["summary"]} for i, p in enumerate(posts)]
            cover = make_digest_cover(date_label, posts)
            fname = f"{date_id} Substacks.epub"
            frags = write_epub(ed_dir / fname, "Substacks", "Substack digest", date_label, cover, picks, posts, "Substacks", "In this digest")
            manifest["files"].append({
                "id": "substacks", "kind": "substacks", "name": "Substacks", "file": fname,
                "url": f"editions/{date_id}/{fname}", "count": len(posts),
                "posts": [{"title": p["title"], "pub": p["section"], "area": p["area"], "summary": p["summary"], "frag": frags.get(i),
                           "mins": p["mins"]} for i, p in enumerate(posts)],
            })
            print(f"  {len(posts)} posts from {len(feeds)} Substacks")
        else:
            print(f"  no new posts from {len(feeds)} Substacks")
    manifest["substack_following"] = following  # shown on the Kindle's Substacks page

    # newspaper PDFs you email in today are print editions (Daily reads, cleared weekly)
    PRINT = [("The Times of India", (" times of india ", " timesofindia ", " toi ")), ("The Hindu", (" hindu ", " thehindu ")),
             ("The Economic Times", (" economic times ", " economictimes ", " et "))]
    today_ist = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=5, minutes=30)).date()
    kept = []
    for b in books:
        paper = None
        if b["name"].lower().endswith(".pdf"):
            norm = " " + re.sub(r"[^a-z0-9]+", " ", (b["name"][:-4] + " " + b.get("subject", "")).lower()) + " "
            paper = next((n for n, pats in PRINT if any(p in norm for p in pats)), None)
        if not paper:
            kept.append(b)
            continue
        when = b.get("when")
        if when and (when + dt.timedelta(hours=5, minutes=30)).date() != today_ist:
            continue  # an older day's paper: skip
        fname = f"{today_ist.isoformat()} {paper} (print).pdf"
        pdir = out / "print"
        pdir.mkdir(parents=True, exist_ok=True)
        data = b["data"]
        try:
            import kindlefit
            data = kindlefit.fit(data)  # cut into screen-sized sections for the 6-inch screen
        except Exception as e:
            print(f"  ! couldn't resize {paper} for the Kindle, sending it as is: {e}", file=sys.stderr)
        (pdir / fname).write_bytes(data)
        manifest["files"].append({"id": "print:" + paper, "kind": "print", "name": paper, "file": fname, "url": "print/" + fname})
        print(f"  print edition: {paper}")
    books = kept

    # books from the inbox go to the Books folder on the Kindle (kept, never cleared)
    if books:
        print(f"• Books: {len(books)}")
        bdir = out / "books"
        bdir.mkdir(parents=True, exist_ok=True)
        for b in books:
            (bdir / b["name"]).write_bytes(b["data"])
            manifest["files"].append({"id": "book:" + b["name"], "kind": "book", "name": b["name"], "file": b["name"],
                                      "url": "books/" + b["name"], "folder": "Books"})

    out.mkdir(parents=True, exist_ok=True)
    (out / "today.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    print(f"Done: {len(manifest['files'])} files → {out}")


if __name__ == "__main__":
    main()
