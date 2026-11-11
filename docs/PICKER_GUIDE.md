# Particle picker guide

Open a folder of micrographs (`.mrc`, `.mrcs`, `.dm3`, `.dm4`). The folder becomes the **project**: picks are stored in
`picks_project.json` there (autosave 1.5 s after each edit, atomic write, rolling backups in `backups/`, newest 30 kept).
Press **P** (or the Pick toolbar button) to enter pick mode; the **Picks** tab of the inspector holds all controls.

## Coordinates
Pick coordinates are array indices of the micrograph: x = column, y = row, origin top-left, y down, pixel centers at integer
values. No y flip. MRC files are read as stored (row 0 on top), the same convention as numpy/mrcfile, RELION `_rlnCoordinateX/Y`
and the web picker. Sizes are kept in nm and converted with the pixel size of each micrograph (uncalibrated files assume 1 Å/px).

## Typical workflow
1. **Size**: set the particle diameter (nm) and extraction box (nm) in the Picks tab. Markers and boxes follow the pixel size.
2. **Find particles**: choose *Bright core* (bright core minus dark annulus; good for stain) or *LoG blob*, set polarity, adjust
   the score threshold; ghost circles (dashed) appear. *Live* re-runs on every slider change. Repeated runs replace each other
   in one undo step; accepted and dismissed picks are never overwritten.
3. **Clean up**: click a ghost to accept it, right-click or ⌫ to remove, drag to move, shift-drag to box-select, `1`–`6` to label,
   `,` / `.` to resize (selection or default), *Remove overlaps*, *Remove edge picks*, score cutoff + *Dismiss hidden*, `A` accept all shown.
4. **Review** with the **Gallery** (G): crops grouped by label (this micrograph or all), relabel / delete / accept, double-click to jump to the pick.
   **Swipe mode** (S): one card per candidate, → particle, ← reject, ↑ unsure, ↓ later, 1–9 label, click to re-center, Space zoom out, Z undo.
   About 8 % of cards are blind random spots (control); they are logged, never exported.
5. **Classes**: *Load classification…* with a RELION `run_itNNN_data.star` colors every pick by its class (average shown if
   `run_itNNN_classes.mrcs` is next to it). Select, relabel or remove a whole class on all micrographs.
6. **Export**: RELION, CSV, EMAN. Mark micrographs *Done* and export only those if needed.

## Keys (pick mode on)
| Key | Action |
|---|---|
| click | add pick (active label) / select / accept a ghost |
| drag a pick | move (all selected move together) |
| drag empty | pan |
| shift-drag | rubber-band select |
| right-click | delete pick under cursor (or the selection) |
| ⌫ | delete selection (auto picks are *dismissed*, manual picks removed) |
| 1–9 / label keys | set the active label and relabel the selection |
| Return | accept selected ghosts |
| A | accept all visible ghosts |
| , / . | shrink / grow selection, or the default diameter if nothing is selected |
| V / B | show markers / boxes |
| Esc | deselect, then leave pick mode |
| ⌘Z / ⇧⌘Z | undo / redo (per micrograph) |
| P, G, S | pick mode, gallery, swipe mode |

Reserved (cannot be label hotkeys): A B F G I P S V , . = + -.

## Labels
New projects start with the **Quality** scheme: `good` (1), `maybe` (2), `reject` (3, not exported). The **Views** preset is the web
picker's six labels (ring_top, side, tilted, oligomer, uncertain, reject). Choose a preset or edit labels in *Edit labels…*
(name, color, hotkey, marker shape, exported flag), or by hand in `labels.json` in the project folder; a valid `labels.json` is
used when a new project is created. Label ids are permanent (they appear in exports). When a preset or edit drops a label that
still has picks, the editor asks where those picks go (pre-filled where there is an obvious match, e.g. uncertain -> maybe) and
writes a project backup first; the move cannot be undone with Cmd-Z.

**Maybe flag (optional).** Tick *Enable the per-pick "maybe" flag* in the label editor. `?` (or `/`) then toggles the flag on the
selected picks, independent of their label (a "?" is drawn on the marker). Export writes a `maybe` column in `all_picks.csv`, and
*Leave out picks flagged maybe* (CLI: `--exclude-maybe`) drops them from the RELION / EMAN files.

## Files
| File | Content |
|---|---|
| `picks_project.json` | scheme, sizes, per-micrograph picks (x, y, label, score, source, status), auto-pick parameters, swipe decisions |
| `backups/picks_project_*.json` | rolling backups (at most one per 5 min) |
| `labels.json` | optional label scheme |
| `picks_export/` (default) | `all_picks.csv`, `<dataset>/<label>/<micrograph>.star`, `<dataset>/coords_list_<label>.star`, `box/…` (EMAN), `swipe_decisions.csv`, `swipe_stats.json` |

`dataset` = the micrograph's folder relative to the project (e.g. `Micrographs_raw`). Only accepted picks of labels with *exported* are
written. The layout and number formats equal the web picker's `picks_export/` (star files were verified byte-identical); `all_picks.csv`
has the same first ten columns plus `score`, `source`. `coords_list_*.star` uses project-relative paths (micrograph key, and the export
folder relative to the project), so copy the folder into the RELION project or edit the prefix. A re-export deletes only the files the
previous export wrote (`.export_manifest.json`) and never anything else.

EMAN `.box`: x, y = box corner (center − box/2), box size in px, origin top-left, y down. This convention is not verified against the EMAN GUI.

## Import
File ▸ Picks ▸ *Import Picks…* accepts RELION coordinate `.star` (or `coords_list.star`, following the files it lists), CSV with
x/y columns (and optional micrograph / label / score), the web picker's `picks.json` and `swipe.json`. Names such as `F4a_000_core.star`
are matched to `F4a_000.mrc`. Already present picks (within 1 px) are skipped. *Import as candidates* loads them as ghosts for review.

## Auto-picker details
Bin so the particle is 10–20 px, optional flatten (Gaussian background), robust z-score (median/MAD), polarity, smoothing
(σ = 0.1 × diameter), score = mean(core r ≤ 0.65 R) − mean(annulus 1.4–2.9 R) or a difference of Gaussians (σ = R/√2 and 1.6×),
robust z of the score map, local maxima ≥ threshold, greedy minimum separation (0.9 × diameter), edge margin (half a diameter), top
*max picks* by score, 3×3 centroid refinement. CPU, a few hundred ms on a 4096² micrograph. Stain and cryo behave differently:
the dark halo built into the core score is a property of the method, not of the sample, so trust positions and sizes more than the halo.

## External picker
*External picker command* runs `/bin/zsh -c "<command>"` with `{mic}` (quoted path) and `{angpix}` substituted and expects JSON
`[{"x":..,"y":..,"score":..}]` on stdout; results appear as ghosts. The command runs with your user rights.

## Tests
`Thon --picktest` runs the headless checks. The GUI (overlay, mouse handling, inspector, sheets)
is not covered by them and has to be checked by hand: see the checklist in CHANGELOG.md.
