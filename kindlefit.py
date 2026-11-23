"""Make a full-size newspaper PDF readable on the Kindle Paperwhite (758 x 1024, 6-inch screen).

Each page becomes an overview of the whole page, then 12 screen-sized sections:
3 columns x 4 rows, read down the left third, then the middle, then the right, the way
newspaper columns run. Sections overlap slightly so no line is cut in half for good.
Pages are greyscale JPEGs at the Kindle's size, so the file stays small and turns fast.
"""
from __future__ import annotations

import pymupdf as fitz  # PyMuPDF

W, H = 758, 1024          # Kindle Paperwhite 2 screen
COLS, ROWS = 3, 4
OVERLAP = 0.04            # share of a section repeated on each side


def _trim(page) -> fitz.Rect:
    """The page minus empty margins (falls back to the whole page)."""
    r = page.rect
    try:
        boxes = [b[:4] for b in page.get_text("blocks")]
        boxes += [img["bbox"] for img in page.get_image_info()]
        boxes = [fitz.Rect(b) & r for b in boxes]
        boxes = [b for b in boxes if not b.is_empty and b.width > 2 and b.height > 2]
        if boxes:
            u = fitz.Rect(boxes[0])
            for b in boxes[1:]:
                u |= b
            pad = 6
            u = fitz.Rect(u.x0 - pad, u.y0 - pad, u.x1 + pad, u.y1 + pad) & r
            if u.width > r.width * 0.5 and u.height > r.height * 0.5:
                return u
    except Exception:
        pass
    return r


def _shot(page, clip: fitz.Rect, doc_out, quality: int = 72):
    """Render clip to fit the screen (greyscale) and add it as a page."""
    scale = min(W / clip.width, H / clip.height) * 1.25  # a little extra for zooming
    pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=clip, colorspace=fitz.csGRAY, alpha=False)
    data = pix.tobytes("jpeg", jpg_quality=quality)
    out = doc_out.new_page(width=W, height=H)
    iw, ih = pix.width, pix.height
    f = min(W / iw, H / ih)
    w, h = iw * f, ih * f
    out.insert_image(fitz.Rect((W - w) / 2, (H - h) / 2, (W + w) / 2, (H + h) / 2), stream=data)


def fit(pdf_bytes: bytes) -> bytes:
    src = fitz.open(stream=pdf_bytes, filetype="pdf")
    out = fitz.open()
    for page in src:
        area = _trim(page)
        _shot(page, area, out, quality=60)              # whole-page overview
        if area.width / area.height > W / H * 1.6:      # already screen-shaped (e.g. a small page): no sections
            continue
        cw, rh = area.width / COLS, area.height / ROWS
        ox, oy = cw * OVERLAP, rh * OVERLAP
        for c in range(COLS):
            for r in range(ROWS):
                clip = fitz.Rect(area.x0 + c * cw - ox, area.y0 + r * rh - oy,
                                 area.x0 + (c + 1) * cw + ox, area.y0 + (r + 1) * rh + oy) & area
                _shot(page, clip, out)
    toc = [[1, f"Page {i + 1}", i * (1 + COLS * ROWS) + 1] for i in range(len(src))]
    try:
        out.set_toc(toc)
    except Exception:
        pass
    data = out.tobytes(garbage=3, deflate=True)
    src.close(); out.close()
    return data


if __name__ == "__main__":
    import sys
    raw = open(sys.argv[1], "rb").read()
    open(sys.argv[2], "wb").write(fit(raw))
