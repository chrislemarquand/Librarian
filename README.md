# Librarian

**Curate your Apple Photos library.**

Librarian is a native macOS companion app for Apple Photos. It helps you reduce a large, overwhelming library into a smaller, more meaningful one — without permanently deleting a single photo until you've safely archived it first.

---

## Why Librarian

Most Photos libraries grow for years without ever being edited. Screenshots, near-duplicates, accidental shots, and low-quality images pile up alongside the photos that actually matter. Librarian gives you a structured, safe way to work through that backlog.

It sits alongside Photos, not in place of it. Photos remains your library; Librarian is the tool you use to curate it.

---

## How It Works

Librarian indexes your Photos library and organises your photos into focused **review queues** — groups of photos that are likely candidates for removal. You review each queue at your own pace, set aside anything you want to remove, and when you're ready, Librarian exports and verifies an archive before anything leaves your library.

**Nothing is deleted from Photos until:**
1. The export to your archive is complete.
2. The archive is verified.
3. You confirm.

---

## Review Queues

| Queue | What it shows |
|---|---|
| **All Photos** | Your full library |
| **Recents** | Photos from the last 30 days |
| **Favourites** | Your starred photos |
| **Screenshots** | Screenshots detected by Photos |
| **Duplicates** | Near-duplicate clusters identified by on-device Vision analysis |
| **Low Quality** | Photos with low quality scores from local analysis |
| **Not in Album** | Photos that don't belong to any album in Photos |
| **Receipts & Documents** | Photos of documents, receipts, and text-heavy images |
| **WhatsApp** | Photos imported from WhatsApp |
| **Set Aside** | Photos you've flagged for archiving |
| **Archived** | Photos already exported to your archive |

---

## Archive Safety

Librarian exports photos to an archive folder you control before removing anything from Photos. The archive uses a simple `YYYY/MM/DD` folder layout and is managed with a local control file — no proprietary format, no lock-in.

Export is powered by a bundled copy of [ExifTool](https://exiftool.org) and [osxphotos](https://github.com/RhetTbull/osxphotos), so originals and edited versions are both preserved, complete with metadata.

---

## Local-First Intelligence

All analysis runs on your Mac. There's no cloud upload, no subscription, and no account required.

- **Vision** performs OCR and near-duplicate detection.
- **Core ML** drives quality scoring and content classification.
- Results are stored locally in a SQLite database alongside your library.

---

## Requirements

- macOS 26 or later
- Apple Photos library
- Apple silicon Mac recommended

---

## Getting Librarian

Librarian is distributed as a signed and notarised direct-download app — no App Store required.

Download the latest release from the [Releases](https://github.com/chrislemarquand/Librarian/releases) page and open the DMG. Librarian checks for updates automatically using [Sparkle](https://sparkle-project.org).

---

## Open Source Acknowledgements

Librarian is built on the shoulders of several excellent open source projects:

- [osxphotos](https://github.com/RhetTbull/osxphotos) — © 2019–2021 Rhet Turnbull (MIT)
- [ExifTool](https://exiftool.org) — © Phil Harvey (Artistic/GPL)
- [Sparkle](https://sparkle-project.org) — © 2006 Andy Matuschak et al. (MIT)
- [WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit) — © 2022 Sven Tiigi (MIT)

---

© 2026 Chris Le Marquand
