# Thon reference

Features, command-line helpers, self-tests and file-format notes. The [README](../README.md) has the short version.

## Features

* Exposure list (recursive folder scan, drag-and-drop): embedded GMS thumbnail, indicated magnification, pixel size, dimensions, acquisition time; sort by name / time / magnification.
* Image: pan (drag), zoom at cursor (wheel / pinch), double-click or `F` to fit, `1` for 100 %, `I` invert, ←/→ previous/next. Scale bar from the calibration, cursor position (px and nm) and raw pixel value. `M` opens the measure tool (drag a line, read its length in nm and px). View ▸ Show Lengths in Ångströms (⌥⌘U) switches all lengths between nm and Å.
* Display: auto contrast (percentile or mean ± nσ) or manual black/white points, gamma, invert; GPU Gaussian low-pass and large-scale background flattening.
* Overview tab: histogram with the contrast window, plus File / Image / Acquisition / Microscope / Session sections pulled from the DM tags (pixel size, FOV, mean signal in e⁻/Å² when the intensity calibration is in electrons, camera, exposure, binning, drift, voltage, magnification, stage, …).
* FFT tab: tile-averaged power spectrum (Hann-windowed, 50 % overlapping tiles; box size 256–2048 px) with resolution rings in Å, an optional "Flatten background" view that subtracts the slow radial trend of the log-power so Thon rings stand out, and the radial profile. A CTF card fits defocus (and astigmatism, if it clearly improves the fit) and draws the fitted zeros on the spectrum. It is a diagnostic only; nothing is corrected.
* Tags tab: every tag in the file, filterable.
* Export: PNG (current contrast), MRC float32 raw or filtered (rows flipped to MRC bottom-left origin; pixel size written to the cell). Note: the picker reads MRC files as stored (row 0 on top, like RELION / mrcfile), so an MRC exported from here appears upside down relative to the DM view if you open it again.

## Command-line helpers

    Thon --dump FILE.dm4 [--tags] [--fft]                 # metadata summary, stats, optional full tag list / FFT profile
    Thon --autopick FILE.mrc [--diameter nm] [--z 4] [--method core|log] [--dark] [--flatten nm] [--max n]   # prints x,y,score CSV
    Thon --export-picks PROJECT_DIR|FILE.thon OUT_DIR [--eman] [--no-csv] [--done] [--session ID]                                    # export picks_project.json without the GUI
    Thon --render FILE.dm4 OUT.png [--lowpass S] [--flatten S] [--size WxH] [--invert]   # offscreen Metal render

## Self-test

The Metal shaders are compiled at launch from source embedded in `Shaders.swift`. Verify them and the GPU filters
against CPU reference implementations once:

    .build/release/Thon --selftest

It prints PASS/FAIL per check (shader compile, Gaussian low-pass, background flatten, nearest/bilinear/pyramid
rendering, invert) and exits non-zero on failure. It then runs the CPU logic tests of the picker (same as `--picktest`).

    .build/release/Thon --picktest    # headless: MRC, picks, auto-picker, import/export, gallery, swipe

## File format notes

* Pixel size is read from the image Calibrations (nm, µm, Å) of the largest non-RGB image in the file; the 384×384 RGB entry is the GMS thumbnail.
* MRC modes 0, 1, 2, 6 and 12 (either byte order, extended header skipped) are read; pixel size comes from cell / grid size (a cell equal to the grid, i.e. 1.0 Å/px, is treated as uncalibrated).
* DM3 (32-bit lengths) and DM4 (64-bit lengths), little- and big-endian, int/uint 8–32, float32/64 and complex (magnitude) pixel types are handled; stacks show frame 0 with a frame stepper.
* No CTF correction is applied anywhere.
* The Apple Neural Engine is not used. It can only be reached through Core ML, and nothing in this viewer is a neural network. Rendering and filtering run on the GPU through Metal; the FFT runs through Accelerate.
