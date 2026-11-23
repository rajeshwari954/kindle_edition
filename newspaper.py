"""Lays out a paper as a real newspaper PDF sized exactly to the Kindle screen (758x1024).

Front page: masthead (the paper's name set in type, never its logo), the lead story with a
standfirst and opening columns, an "Also today" box with the other top picks, and an index.
Inside: section pages with two justified columns, rules and running heads, like a broadsheet.
Every headline links to its story, so tapping on the Kindle jumps there.
"""
from __future__ import annotations

import datetime as dt
import html
import re
from pathlib import Path

ROOT = Path(__file__).parent
FONTS = ROOT / "fonts"


def esc(s):
    return html.escape(s or "", quote=True)


def words(raw, n):
    t = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", raw or ""))).strip()
    w = t.split()
    return " ".join(w[:n]) + ("…" if len(w) > n else "")


CSS = """
@font-face { font-family: Display; font-weight: 700; src: url(%(f)s/news/playfair-display-latin-700-normal.woff); }
@font-face { font-family: Display; font-weight: 900; src: url(%(f)s/news/playfair-display-latin-900-normal.woff); }
@font-face { font-family: Display; font-style: italic; font-weight: 700; src: url(%(f)s/news/playfair-display-latin-700-italic.woff); }
@font-face { font-family: Text; font-weight: 400; src: url(%(f)s/news/source-serif-4-latin-400-normal.woff); }
@font-face { font-family: Text; font-weight: 700; src: url(%(f)s/news/source-serif-4-latin-700-normal.woff); }
@font-face { font-family: Text; font-style: italic; src: url(%(f)s/news/source-serif-4-latin-400-italic.woff); }
@font-face { font-family: Sans; src: url(%(f)s/DMSans.ttf); }

@page { size: 758px 1024px; margin: 46px 30px 40px;
  @top-left { content: string(paper) " · " string(day); font: 12px Sans; color: #444; vertical-align: bottom; padding-bottom: 8px; border-bottom: 1px solid #111; }
  @top-right { content: string(section); font: 700 12px Sans; letter-spacing: .08em; text-transform: uppercase; vertical-align: bottom; padding-bottom: 8px; border-bottom: 1px solid #111; }
  @bottom-center { content: counter(page); font: 12px Sans; color: #444; }
}
@page front { margin: 24px 30px 34px; @top-left { content: none; border: 0 } @top-right { content: none; border: 0 } }

html { font-family: Text; font-size: 21px; line-height: 1.36; color: #111; hyphens: auto; }
a { color: inherit; text-decoration: none; }
.front { page: front; height: 962px; overflow: hidden; }
.strings { string-set: paper attr(data-paper), day attr(data-day); height: 0; }

/* masthead */
.ears { display: flex; justify-content: space-between; font: 700 11px Sans; letter-spacing: .1em; text-transform: uppercase; border-bottom: 1px solid #111; padding-bottom: 6px; }
.name { font: 900 66px/1 Display; text-align: center; margin: 10px 0 6px; letter-spacing: -.01em; }
.name.long { font-size: 52px; }
.dbl { border-top: 3px solid #111; border-bottom: 1px solid #111; height: 3px; }
.nav { font: 12px Sans; text-align: center; letter-spacing: .06em; text-transform: uppercase; padding: 7px 0; border-bottom: 1px solid #111; }

/* front page */
.lead { margin-top: 12px; }
.kicker { font: 700 12px Sans; letter-spacing: .12em; text-transform: uppercase; }
.lead h2 { font: 900 34px/1.08 Display; margin: 4px 0 8px; }
.stand { font: italic 19px/1.32 Text; margin: 0 0 10px; color: #222; }
.cols { font-size: 18px; line-height: 1.34; column-count: 2; column-gap: 26px; column-rule: 1px solid #bbb; text-align: justify; }
.cols p { margin: 0 0 .5em; }
.more { font: 700 13px Sans; display: block; margin-top: 4px; }
.below { margin-top: 12px; border-top: 3px solid #111; padding-top: 8px; }
.below h3 { font: 700 italic 22px Display; margin: 0 0 4px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; column-gap: 22px; }
.item { display: block; border-top: 1px solid #bbb; padding: 7px 0 8px; }
.item .pg { font: 700 11px Sans; letter-spacing: .08em; }
.item b { font: 700 18px/1.18 Display; display: block; margin: 2px 0 3px; }
.item span.why { font-size: 14px; line-height: 1.28; display: block; }
.index { margin-top: 10px; border-top: 1px solid #111; border-bottom: 1px solid #111; padding: 7px 0; font: 13px Sans; text-align: center; letter-spacing: .03em; }
.index b { font-weight: 700; text-transform: uppercase; letter-spacing: .1em; margin-right: 6px; }

/* inside pages */
.section { break-before: page; string-set: section attr(data-name); }
.secbar { font: 900 34px Display; border-bottom: 3px solid #111; padding-bottom: 4px; margin-bottom: 12px; }
.secflow { column-count: 2; column-gap: 26px; column-rule: 1px solid #bbb; column-fill: auto; }
.story { margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid #111; }
.story h4 { font: 700 26px/1.12 Display; margin: 0 0 6px; text-align: left; }
.story .meta { font: 11px Sans; letter-spacing: .05em; text-transform: uppercase; color: #444; margin-bottom: 6px; }
.story .short { font: italic 18px/1.3 Text; margin: 0 0 8px; border-left: 3px solid #111; padding-left: 8px; }
.story .body { text-align: justify; }
.story .body p { margin: 0 0 .45em; text-indent: 1em; }
.story .body p:first-child { text-indent: 0; }
.story .src { font: 10px Sans; color: #555; word-break: break-all; }
.story.top h4 { font-size: 30px; }
"""


def render_paper(paper: dict, stories: list[dict], picks: list[dict], when: dt.datetime) -> tuple[bytes, dict]:
    """Returns (pdf bytes, {story index: page number})."""
    from weasyprint import HTML

    day_long = when.strftime("%A, %d %B %Y").replace(" 0", " ")
    day = when.strftime("%a %d %b").replace(" 0", " ")
    name = paper["name"]
    sections: dict[str, list[int]] = {}
    for i, s in enumerate(stories):
        sections.setdefault(s["section"], []).append(i)
    lead = picks[0] if picks else {"i": 0, "tag": stories[0]["section"], "why": ""}
    others = picks[1:5]
    ls = stories[lead["i"]]

    nav = " · ".join(esc(s) for s in sections)
    parts = ['<div class="front">',
             f'<div class="strings" data-paper="{esc(name)}" data-day="{esc(day)}"></div>',
             f'<div class="ears"><span>{esc(day_long)}</span><span>{esc(paper.get("subtitle", ""))}</span></div>',
             f'<div class="name{" long" if len(name) > 14 else ""}">{esc(name)}</div>',
             '<div class="dbl"></div>',
             f'<div class="nav">{nav}</div>',
             '<div class="lead">',
             f'<div class="kicker">{esc(lead.get("tag") or ls["section"])}</div>',
             f'<h2><a href="#s{lead["i"]}">{esc(ls["title"])}</a></h2>',
             f'<p class="stand">{esc(lead.get("why", ""))}</p>',
             f'<div class="cols"><p>{esc(words(ls["body"], 80))}</p>'
             f'<a class="more" href="#s{lead["i"]}">Full story, page <span class="ref" data-t="s{lead["i"]}"></span> →</a></div>',
             '</div>',
             '<div class="below"><h3>Also today</h3><div class="grid">']
    for p in others:
        st = stories[p["i"]]
        parts.append(f'<a class="item" href="#s{p["i"]}"><span class="pg">{esc((p.get("tag") or st["section"]).upper())} · P. '
                     f'<span class="ref" data-t="s{p["i"]}"></span></span>'
                     f'<b>{esc(st["title"])}</b><span class="why">{esc(p.get("why", ""))}</span></a>')
    parts.append('</div><div class="index"><b>Inside</b>')
    parts.append(" · ".join(f'<a href="#sec-{esc(re.sub(r"\W+", "-", sec))}">{esc(sec)} {len(idxs)}</a>' for sec, idxs in sections.items()))
    parts.append('</div></div></div>')

    pick_ids = {p["i"] for p in picks}
    for sec, idxs in sections.items():
        sid = re.sub(r"\W+", "-", sec)
        parts.append(f'<div class="section" id="sec-{esc(sid)}" data-name="{esc(sec)}"><div class="secbar">{esc(sec)}</div><div class="secflow">')
        for i in sorted(idxs, key=lambda k: (k not in pick_ids, k)):
            s = stories[i]
            when_s = s["when"].astimezone(when.tzinfo).strftime("%d %b, %H:%M") if s.get("when") else ""
            meta = " · ".join(x for x in [s.get("author", ""), when_s] if x)
            short = next((p.get("why") for p in picks if p["i"] == i), "")
            parts.append(f'<div class="story{" top" if i in pick_ids else ""}" id="s{i}"><h4>{esc(s["title"])}</h4>'
                         + (f'<div class="meta">{esc(meta)}</div>' if meta else "")
                         + (f'<p class="short">{esc(short)}</p>' if short else "")
                         + f'<div class="body">{s["body"]}</div><div class="src">{esc(s.get("link", ""))}</div></div>')
        parts.append('</div></div>')

    doc_html = "<!doctype html><html lang='en'><head><meta charset='utf-8'><style>" + CSS % {"f": FONTS.as_uri()} + "</style></head><body>" + "".join(parts) + "</body></html>"

    # first pass: find which page each story lands on, then fill in "page N" references
    doc = HTML(string=doc_html, base_url=str(ROOT)).render()
    pages = {}
    for n, pg in enumerate(doc.pages, 1):
        for anchor in pg.anchors:
            if anchor.startswith("s") and anchor[1:].isdigit():
                pages.setdefault(int(anchor[1:]), n)
    doc_html = re.sub(r'<span class="ref" data-t="s(\d+)"></span>', lambda m: str(pages.get(int(m.group(1)), "")), doc_html)
    pdf = HTML(string=doc_html, base_url=str(ROOT)).write_pdf()
    return pdf, pages
