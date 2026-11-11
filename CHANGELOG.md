# Changelog

## Swipe mode: brightness, contrast and denoising, always labelled
* New **Display** panel in swipe mode: brightness, contrast, gamma, invert, window from the whole micrograph (same on every card) or from this card (0.5–99.5 % stretch), and a **Show true pixels** toggle (nearest neighbour, no interpolation).
* Denoise (display only): Gaussian, median, bilateral, non-local means, with size / strength sliders. Noise σ for the bilateral and NL-means strength is estimated from the card's own raw pixels (shown as σn; assumes uncorrelated noise, so it is a lower bound).
* The card always says what you are looking at: a badge on the card (**RAW**, or **DENOISED** plus method and settings, black on orange), a dashed orange frame while denoised, and a caption under the card with pixel size, enlargement / downsampling and the tone settings.
* **Denoising reverts to raw on every new card** unless "Keep on next cards" is ticked. Brightness / contrast / gamma / invert carry over.
* Keys: V denoise on/off (back to the last method), `,` `.` brightness, `-` `=` contrast, I invert, 0 reset display. All are reserved label keys, so they never collide with label hotkeys.
* Changed: the card used to be smoothed with a hidden σ = 1 px Gaussian; the default is now raw pixels (only the resampling to the card size remains, and the caption states it).
* Picks, coordinates and exports never use the processed image. Each swipe decision now stores the display state it was made with (`view` in the project JSON, new last column `display` in `swipe_decisions.csv`, e.g. `raw`, `nlm(1.0)`, `gauss(1.5) b+0.30 c1.00 g1.00`).
* `--picktest` has a new "swipe display" suite (byte-identical raw render vs. the thumbnail renderer, noise estimate, denoiser noise reduction and edge behaviour, border padding, tone window, true pixels, badge / log text, revert / pin, CSV column).

## Welcome screen and shorter README
* New welcome screen shown while nothing is open: actions on the left (Open Files… names DM3, DM4, MRC and MRCS), recent projects / folders / files on the right (context menu: Show in Finder, Remove from Recent). File ▸ Open Recent has the same list. The toolbar appears once something is open.
* Recents are stored in UserDefaults (`recentItems`, last 10, missing paths are hidden). A single opened file or folder is remembered as itself; several files as their folder.
* README cut to a short overview; features, command-line helpers, self-tests and file-format notes moved to docs/REFERENCE.md.
* GUI not viewed on screen (typecheck only): check the welcome layout, Open Recent, and that opening an empty folder keeps the welcome screen and shows the alert.

## Projects with sessions (.thon)
* New project file type `.thon` (JSON): the picks, the label scheme and the session organization live in one file you can open from anywhere. File ▸ Open Project… (⌥⌘O), File ▸ New Project from Folders… (⌥⌘N; one session per chosen folder, then choose where to save), or double-click / drop a `.thon` file (Info.plist registers the type once the app is rebuilt).
* A session = a named folder of micrographs with sample / grid, date and notes. Folders can sit in different places or drives; paths are stored relative to the project file with the absolute path as a fallback, so the project file can be moved. Sessions… (sidebar button or File menu) edits them, reorders them, adds or removes a session folder and locates a moved folder.
* Micrograph keys in a `.thon` project are `<session id>/<path inside the session folder>`, so the same file name in three sessions stays distinct, and renaming a session or relocating its folder keeps every pick attached. Removing a session deletes its picks (confirmation, backup written first).
* Sidebar groups micrographs by session in project order (collapsible, with micrograph / pick / candidate / done counts per session; a warning marks a folder that cannot be found).
* Export: Picks ▸ Import / export has a Sessions chooser (all sessions merged, or one). Datasets are named after the session; `coords_list_*.star` and the CSV carry real micrograph paths (relative to the project file's folder when inside it, else absolute). `--export-picks file.thon OUT [--session ID]…` does the same headless.
* Backups go to `<name>_backups/<name>_<time>.thon` (openable files). Plain folder projects (`picks_project.json`) open exactly as before.
* Folder of folders: File ▸ New Project from Folder of Folders… (⌥⇧⌘N) turns every sub-folder of the chosen folder that holds micrographs into a session (natural order; micrographs lying directly in the parent are reported, not added). Sessions… ▸ + ▸ Add Sub-folders as Sessions… does the same for an open project.
* Reorganizing: Sessions… ▸ Micrographs tab lists every micrograph with its session; filter, multi-select and "Move selected to…" another session (or back to its own). Right-click a micrograph in the sidebar ▸ Move to Session works for one. A move only changes which session the micrograph is listed, counted and exported under; the file stays in its folder, its key and picks do not change, and it is stored as a per-micrograph `session` field in the `.thon` file. Moved micrographs are marked "from <session>" in that tab. Removing a session sends micrographs that were moved into it back to their own session; picks of files that live in the removed session's folder are deleted (counted in the confirmation, backup first).
* Export of moved micrographs: dataset = the session they were moved to; if a file name then occurs twice in that session the moved ones go to `<session>__<original session id>` so nothing is overwritten.
* Not included: importing coordinate files by bare file name when several sessions contain the same file name (reported as unmatched), and undo for moves (move back instead).
* Tests: `--picktest` has a new "sessions: .thon project file" suite. The sidebar, Sessions sheet and open / save panels are compile-checked only (no GUI run in the agent sandbox).

## Measure tool and Å / nm display
* Measure tool (toolbar ruler button, `M`, or Measure ▸ Measure Tool): drag to draw a line, drag an endpoint to adjust it, Shift snaps to 45°, Option-drag pans, Delete removes the selected line, right-click removes the one under the cursor, Esc deselects / leaves the tool. Each line is labelled with its length in the current unit and in pixels (pixels only, marked uncalibrated, when the file has no pixel size). Lines are kept per image for the session and are not saved to disk.
* The measure tool and the picker both use the left mouse button, so turning one on turns the other off.
* View ▸ Show Lengths in Ångströms (⌥⌘U) switches every length in the UI between nm and Å and is remembered between launches: scale bar, cursor readout, measure labels, file overview (pixel size, field of view, drift), and the picker's size / smoothing / flatten sliders and swipe window. Stored values do not change (project parameters stay in nm, `box_nm` exports unchanged).
* `--picktest` has a new "measure tool and length units" suite.

## CTF fit
* FFT tab: CTF card fits defocus (and astigmatism, only if it clearly improves the fit) to the flattened spectrum and draws the fitted zeros on it; voltage is read from the file header, Cs / amplitude contrast / fit range are editable. Diagnostic only, nothing is corrected.
* Fit is a ring-profile scan over 0.1 – 60 µm, then a 2-D refinement; the scan range matters because low-magnification stain images can sit at 10 – 25 µm defocus.
* `--dump FILE --fft` prints the fit; `--picktest` includes synthetic recovery tests.

## Thon rings fix
* FFT tab now shows an average of up to 64 overlapping Hann-windowed boxes (default 512 px; 256/512/1024 selectable) instead of one noisy periodogram.
* "Divide by radial mean" removed: it erased circularly symmetric Thon rings. Replaced by "Flatten background", which subtracts only the slow radial trend of log-power.
* New toolbar button and `T` shortcut open the FFT tab; added 100/60/40 Å guide circles for low-resolution rings.
* `--dump FILE --fft --fft-png PREFIX` writes the log and flattened spectra as PNGs.

## Picker (this version)
* `.mrc` / `.mrcs` input (modes 0, 1, 2, 6, 12, either byte order).
* Picker: pick model with undo/redo, label scheme editor, overlay (circle/box/cross/ring), loupe, project autosave + backups.
* Auto-picker (bright core / LoG) with ghost candidates, live mode, clean-up tools, external command hook.
* Import (RELION star, coords_list, CSV, web picker json) and export (RELION, CSV, EMAN) in the web picker's layout.
* Gallery, RELION class back-mapping with class averages, swipe mode with blind decoys and decision log.
* Labels: new projects default to Quality (good / maybe / reject); Views preset keeps the six web-picker labels; presets + remap of dropped labels in the editor; optional per-pick maybe flag (`?`) with `--exclude-maybe` export.
* New CLI modes: `--picktest`, `--autopick`, `--export-picks`. `--selftest` also runs the picker logic tests.

## Manual test checklist (GUI, needs your Mac)
1. `./build_app.sh` finishes; `.build/release/Thon --selftest` and `--picktest --data /path/to/relion-project` print no FAIL.
2. Open `<project>/Micrographs`: .mrc files list with thumbnails and Å/px; picture is upright (row 0 on top).
3. Press P. Click adds a colored circle at the click position; drag moves it; right-click deletes; ⌘Z / ⇧⌘Z work; shift-drag selects.
4. 1–3 (Quality) relabel the selection; Edit labels… ▸ Presets switches scheme and asks where dropped labels' picks go; Edit labels… changes names/colors/hotkeys; a reserved key is refused.
5. Picks tab ▸ Find particles: dashed ghosts appear in a second or less; sliders change them with *Live*; clicking a ghost makes it solid.
6. Zoom/pan with markers on: markers stay on the particles (check at 100 % that the circle center sits on the pixel you clicked; loupe cross agrees).
7. Quit and reopen the folder: picks are restored; `picks_project.json` and `backups/` exist.
8. Import `<project>/coords_list.star` (File ▸ Picks ▸ Import): the picks appear on the matching micrographs.
9. Load classification `<project>/Class2D/run_it100_data.star`: picks colored by class, class averages listed; Select / Relabel work.
10. Gallery (G): crops appear (this micrograph, then all micrographs); relabel and delete work; double-click jumps to the pick.
11. Swipe (S): arrows and keys decide cards; click re-centers the cross; Z undoes; level-finished screen shows counts.
12. Swipe display: badge says RAW on a new card. V turns on denoising (orange DENOISED badge + dashed frame); the next card is RAW again unless "Keep on next cards" is ticked. `,` `.` `-` `=` change brightness / contrast, 0 resets. "Show true pixels" shows square pixels. After deciding a few cards, the exported `swipe_decisions.csv` has a `display` column.
12. Export…: check `picks_export/` (star files, all_picks.csv, coords_list_*.star) and that a second export replaces, not duplicates.
