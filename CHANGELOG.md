# Changelog

## Picker (this version)
* `.mrc` / `.mrcs` input (modes 0, 1, 2, 6, 12, either byte order).
* Picker: pick model with undo/redo, label scheme editor, overlay (circle/box/cross/ring), loupe, project autosave + backups.
* Auto-picker (bright core / LoG) with ghost candidates, live mode, clean-up tools, external command hook.
* Import (RELION star, coords_list, CSV, web picker json) and export (RELION, CSV, EMAN) in the web picker's layout.
* Gallery, RELION class back-mapping with class averages, swipe mode with blind decoys and decision log.
* New CLI modes: `--picktest`, `--autopick`, `--export-picks`. `--selftest` also runs the picker logic tests.

## Manual test checklist (GUI, needs your Mac)
1. `./build_app.sh` finishes; `.build/release/Thon --selftest` and `--picktest --data /path/to/relion-project` print no FAIL.
2. Open `<project>/Micrographs`: .mrc files list with thumbnails and Å/px; picture is upright (row 0 on top).
3. Press P. Click adds a colored circle at the click position; drag moves it; right-click deletes; ⌘Z / ⇧⌘Z work; shift-drag selects.
4. 1–6 relabel the selection; Edit labels… changes names/colors/hotkeys; a reserved key is refused.
5. Picks tab ▸ Find particles: dashed ghosts appear in a second or less; sliders change them with *Live*; clicking a ghost makes it solid.
6. Zoom/pan with markers on: markers stay on the particles (check at 100 % that the circle center sits on the pixel you clicked; loupe cross agrees).
7. Quit and reopen the folder: picks are restored; `picks_project.json` and `backups/` exist.
8. Import `<project>/coords_list.star` (File ▸ Picks ▸ Import): the picks appear on the matching micrographs.
9. Load classification `<project>/Class2D/run_it100_data.star`: picks colored by class, class averages listed; Select / Relabel work.
10. Gallery (G): crops appear (this micrograph, then all micrographs); relabel and delete work; double-click jumps to the pick.
11. Swipe (S): arrows and keys decide cards; click re-centers the cross; Z undoes; level-finished screen shows counts.
12. Export…: check `picks_export/` (star files, all_picks.csv, coords_list_*.star) and that a second export replaces, not duplicates.
