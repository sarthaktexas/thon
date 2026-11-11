# Particle picker – design notes

Goal: pick, label and clean particles inside Thon. Auto-pick first, then edit (resize, remove junk,
relabel). Modeled on an earlier browser-based picker used for 2D-class curation (labels 1-6, autosave,
RELION .star export, gallery, swipe mode).

## Hooks in the existing code (audit)
| Need | Where |
|---|---|
| Image pixels, size, Å/px | `AppModel.doc` (`LoadedExposure.pixels`, `.entry.width/height/pixelSizeA`) |
| Pan/zoom transform | `ViewState`: `zoom` = drawable px per image px, `center` = image px at view center, `viewPixels` (drawable px), `backingScale`. Screen point (pt) -> image px: `img = center + (pt*backingScale - viewPixels/2)/zoom` |
| Mouse events | `InteractiveMTKView` (MetalView.swift): drag=pan, wheel=zoom. Needs a pick-tool mode that intercepts click/drag |
| Keys | `AppModel.handleKey` – digits 1-6 are currently "zoom 100 %" for `1`; picker mode takes precedence for digits |
| Overlays | `ImagePane` ZStack (Views.swift) – picks overlay is added between `MicrographView` and header/scale bar |
| Inspector tabs | `InspectorTab` enum + `InspectorView` switch -> new `Picks` tab |
| File list | `AppModel.items` (dm3/dm4 only -> add mrc/mrcs) |
| Filtered image for auto-picker | CPU path (Accelerate) on `doc.pixels`; GPU path is display-only |

Constraints: no `@State` (macro plugin fails in the agent sandbox) – view state lives in ObservableObjects.
Core logic (MRC, picks, auto-picker, IO) uses Foundation/Accelerate only so it compiles and is tested headlessly
(`PickTests.swift`, `--picktest`).

## Coordinate convention
* Picks are stored in **native pixels of the micrograph array, origin top-left, x right, y down**; pixel centers are at integer
  values, so a pick at (x, y) refers to array element `[row=y, col=x]` (same as numpy/mrcfile, RELION `_rlnCoordinateX/Y` and the web
  picker's `picks.json`). The viewer's continuous image coordinates (pixel i spans [i, i+1)) differ by 0.5: pick = viewer − 0.5.
* DM3/DM4 data are stored top-down, so no flip. MRC files are read **as stored** (row 0 on top, no flip), as the
  web picker, mrcfile and RELION do. (IMOD displays row 0 at the bottom; not supported as a display convention.)

## Data model
```
Pick       { id, x, y, label (label id), score?, source: manual|auto, diameterNm? (override), status: candidate|accepted|dismissed }
MicRecord  { key, done, note, picks[], autoParams? }
Project    { version, scheme, params{box_nm, diameter_nm}, mics{ key -> MicRecord } }
```
* `key` = path of the micrograph relative to the project folder (so a project folder can move).
* `status = candidate` is a ghost (auto, not yet accepted); `dismissed` candidates are kept so re-running the
  auto-picker does not resurrect them (suppressed within 0.5 diameter). Only `accepted` picks are exported.
* Undo/redo: snapshot-free command stack (add/remove/move/relabel/resize/status/bulk), per micrograph.
* Autosave: debounced 1.5 s to `picks_project.json` (atomic write), rolling backups to the hidden `.backups/` at most every 5 min,
  keep newest 30.

## LabelScheme
`labels.json` next to the project (or inside `picks_project.json`). Default for new projects = Quality: `good 1 #4dff6a`,
`maybe 2 #ffd400`, `reject 3 #9a9a9a` (reject not exported). Preset "Views" = the web picker's six labels: `ring_top 1 #ff4d4d`,
`side 2 #ffd400`, `tilted 3 #35e0ff`, `oligomer 4 #4dff6a`, `uncertain 5 #ff7bf5`, `reject 6 #9a9a9a`; a project file with no stored
scheme is read as Views. Each label: id, name, hotkey (1-9), color, marker shape (circle|box|cross|ring), exported (bool).
Editable in the Picks tab (add/remove/rename/recolor/reorder, presets, remap of dropped labels) and by hand in JSON.
Optional `params.maybeFlag` enables a per-pick `maybe` boolean (key `?`), stored only when true.

## Auto-picker (CPU, Accelerate)
1. Optional flatten (large-sigma Gaussian subtract) and robust z-score normalization (MAD).
2. Smooth at `sigma` px.
3. Score map: `core` = mean(core r) - mean(annulus r1..r2) (bright-core, as the F4 picker) or `LoG` at the
   particle scale. Polarity switch (bright/dark particles).
4. Local maxima with min separation, z >= threshold, edge margin, cap per micrograph.
5. Output ghost candidates with score. Sliders re-run on the already computed score map (cheap).
6. Clean-up tools: score cutoff, remove overlaps, remove edge picks, resize all (diameter nm -> px using Å/px).
7. External hook: command that prints JSON `[{"x":..,"y":..,"score":..}]` for a micrograph path.

## Export / import
* RELION: `<out>/<dataset>/<label>/<mic>.star` (`data_` / `loop_` / `_rlnCoordinateX #1` / `_rlnCoordinateY #2`,
  one decimal) and `coords_list_<label>.star`, identical layout to the web picker's `picks_export/`.
* `all_picks.csv` with the web picker's columns (dataset, micrograph, raw, angpix, pick, x_px, y_px, label, box_nm, box_px).
* EMAN `.box` (top-left corner, box size px). Project JSON.
* Import: RELION coordinate `.star`, CSV (x,y[,label]), web picker `picks.json` / `swipe.json`.

## Milestones
1 audit/design (this file) -> 2 MRC reader -> 3 model + persistence -> 4 overlay + editing -> 5 auto-picker ->
6 import/export -> 7 gallery + class back-mapping -> 8 swipe mode -> 9 docs/verification.


_Status: all nine milestones are implemented; see README.md, docs/PICKER_GUIDE.md and CHANGELOG.md._
