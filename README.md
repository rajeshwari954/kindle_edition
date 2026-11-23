# Kindle daily reads

Every morning at 5:53 IST, GitHub builds four newspaper EPUBs (The Times of India, The Hindu,
The Economic Times, LiveLaw) plus a Substack digest. Each paper gets a cover with your texture,
the paper's name set in Marcellus (never its logo), and a "Today's summary" of the 5 stories that
matter, written by Claude. On the Kindle, one tap downloads them, and anything from before the
latest Sunday is deleted.

## One-time setup (about 15 minutes)

### 1. GitHub
1. Create a new **public** repository called `kindle-edition` and upload everything in this folder
   (keep the `.github` folder; it holds the schedule).
2. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
3. **Settings → Secrets and variables → Actions → New repository secret**, twice:
   - `EDITION_KEY` = a random code, e.g. `Jdi_GirwN2AvyGTm`. Editions are served only under this
     folder name, so they aren't publicly listed.
   - `ANTHROPIC_API_KEY` = a key from console.anthropic.com (add a small credit; the daily
     summaries cost roughly ₹50–150 a month). Without it, the summary uses each story's opening lines.
4. **Actions → Morning edition → Run workflow** to build the first edition now.

Your edition address is then: `https://<your-username>.github.io/kindle-edition/<EDITION_KEY>/`

### 2. Kindle
1. Plug the Kindle in. Copy `koreader/plugins/dailyreads.koplugin` into `koreader/plugins/` on the Kindle.
2. Eject, open KOReader. Top menu → **Tools (wrench) → Daily reads → Edition address**, paste the address above, Save.
3. **Daily reads → Download today's reads.** Editions appear in `Daily reads` in your documents.

## Changing things
- Papers, sections, Substacks: edit `config.yaml` on GitHub. Add a Substack as
  `- { name: "Name", url: "https://name.substack.com/feed", area: "Finance & Economics" }`.
- Time of the build: the `cron` line in `.github/workflows/morning.yml` (UTC; 0:23 UTC = 5:53 IST).

## Notes
- TOI and ET feeds give only teasers, so the build fetches the full article page. If a site blocks
  that, the story shows its teaser with the source link.
- Paid Substack posts arrive as previews unless the writer gives you a private feed link.
- Coming next: marking a paper read logs it to the Reading Log (Type: Newspaper, Area: Current Affairs).

## self.v2 on the Kindle (start screen)
`koreader/plugins/selfv2.koplugin` draws Home, Today's papers and Substacks. Backgrounds are baked by
`python kindle/make_screens.py` (run it after changing the design, then commit).
After the first install by cable, updates arrive over Wi-Fi: Home → Settings → Check for updates.

## The Kindle's Gmail inbox (Substacks + books)
Secrets `GMAIL_USER` and `GMAIL_APP_PASSWORD` let the morning job read a dedicated Gmail inbox:
Substack newsletters sent there become the Substack digest; EPUB/PDF attachments go to the
Kindle's `Books` folder (kept, not cleared on Sunday). Books stay available to download for 7 days.
