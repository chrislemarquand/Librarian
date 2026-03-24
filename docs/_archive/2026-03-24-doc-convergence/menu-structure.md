# Librarian — Menu Structure

> Edit this file and hand it back to have menus implemented.
> Mark any item with `[REMOVE]` to drop it, `[RENAME: New Name]` to rename it, or add notes inline.

---

## Menu Bar

### Librarian (App Menu)
Standard — no changes needed.

---

### File

| Item | Key | Notes |
|---|---|---|
| Import Photos into Archive… | | Path A import — bring external files into the archive |
| Set Archive Location… | | Picks archive root folder |
| — | | |
| Open Archive Report… | | View last export report JSON summary | [remove]
| Open in Photos | ⌘O | Opens selection in Photos.app |
| Reveal in Finder | ⌘⌥R | Enabled only when selection is an archived item |
| Quick Look | ⌘Y | Inline preview |

---

### Edit

| Item | Key | Notes |
|---|---|---|
| Undo | ⌘Z | |
| Redo | ⌘⇧Z | |
| — | | |
| Select All | ⌘A | |

---

### Photo

| Item | Key | Notes |
|---|---|---|
| Keep | ⌘K | Records keep decision for the current queue |
| Set Aside | ⌘D | Moves to Set Aside queue |
| Put Back | ⌘⌥D | Removes from Set Aside, returns to queue |
| Reset Decision | ⌘⌫ | Clears keep decision; photo returns to unreviewed in that queue |
| — | | |
| Send Selected to Archive… | ⌘⌥⇧S | Triggers export flow for selected items in Set Aside |


---

### View

| Item | Key | Notes |
|---|---|---|
| Zoom In | ⌘+ | |
| Zoom Out | ⌘− | |
| — | | |
| Toggle Sidebar | ⌘⌥S | |
| Toggle Inspector | ⌘⌥I | |
| — | | AppKit provides Enter Full Screen here |

---

### Window
Standard AppKit — Minimize (⌘M), Zoom, Bring All to Front.

---

### Help
Standard AppKit — no custom items.

---

## Context Menus

### Gallery — Library views (All Photos, Recents, Favourites)

| Item | Notes |
|---|---|
| Keep | Shown but disabled — no active queue |
| Set Aside | |
| — | |
| Open in Photos | |
| Quick Look | |

---

### Gallery — Box views (Screenshots, Duplicates, Low Quality, Documents, WhatsApp, Accidental)

| Item | Notes |
|---|---|
| Keep | |
| Set Aside | |
| Reset Decision | Only shown if selection has a recorded keep decision |
| — | |
| Open in Photos | |
| Quick Look | |

---

### Gallery — Set Aside view

| Item | Notes |
|---|---|
| Send to Archive… | Primary action |
| Put Back | |
| — | |
| Open in Photos | |
| Quick Look | |

---

### Gallery — Archive view

| Item | Notes |
|---|---|
| Reveal in Finder | Primary action |
| — | |
| Open in Photos | If asset still exists in the library |
| Quick Look | |

---

### Sidebar context menus

| Sidebar item | Context menu items |
|---|---|
| All Photos / Recents / Favourites | No context menu |
| Any Box item (Screenshots etc.) | Reset All Decisions in This Queue… (with confirmation) |
| Set Aside | Send All to Archive… / Clear Set Aside… |
| Archive | Open Archive Folder in Finder |
| Log | Clear Log |

---

## Key Equivalents

| Key | Action |
|---|---|
| ⌘, | Settings |
| ⌘O | Open in Photos |
| ⌘Y | Quick Look |
| ⌘K | Keep in Library |
| ⌘D | Set Aside for Archive |
| ⌘⌥D | Put Back |
| ⌘⌫ | Reset Decision |
| ⌘⌥⇧S | Send Selected to Archive |
| ⌘⌥R | Reveal in Finder |
| ⌘+ / ⌘− | Zoom In / Out |
| ⌘⌥S | Toggle Sidebar |
| ⌘⌥I | Toggle Inspector |
| ⌘A | Select All |
| ⌘Z / ⌘⇧Z | Undo / Redo |
