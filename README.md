# Thon

A native macOS viewer for electron micrographs: Gatan `.dm3` / `.dm4` and `.mrc` / `.mrcs`. Exposure list on the left, GPU-rendered image in the middle, inspector on the right.

* View and measure micrographs: pan, zoom, contrast, low-pass and background flattening, scale bar, measure tool.
* Check defocus on the FFT tab: power spectrum with resolution rings and a fitted CTF. Diagnostic only, nothing is corrected.
* Pick particles by hand or with the built-in auto-picker. Topaz and CryoSegNet are optional extras that run in a Python environment you provide.
* Review candidates in the crop editor: one crop at a time, move, resize, add or remove circles and mark each green (sure) or yellow (maybe). It learns from your edits and shows the crops it is least sure about first. You can also swipe through candidates from a phone on the same Wi-Fi ([phone guide](docs/PHONE.md)).
* Label picks and import or export RELION `.star` files ([picker guide](docs/PICKER_GUIDE.md)).
* Group folders into `.thon` projects with one session per grid.

![Fitted CTF zeros overlaid on FFT power spectra of three micrographs](docs/ctf_zeros.png)

## Build and run

Requires macOS 14+ and Xcode 15+ (command-line tools are enough). No third-party Swift dependencies; Python is needed only for the optional Topaz and CryoSegNet engines.

    ./build_app.sh                 # builds Thon.app next to this file
    open Thon.app                  # or: open Thon.app --args /path/to/folder-or-file

Run `.build/release/Thon --selftest` once on a new machine to check the Metal shaders against CPU reference code.

More: [features and file-format notes, command-line helpers, self-tests](docs/REFERENCE.md).

## Name

Thon rings are the oscillating rings in a micrograph's power spectrum that you read defocus from.

## License

MIT, see [LICENSE](LICENSE). Not affiliated with or endorsed by Gatan, cryoSPARC or RELION; those names only describe file formats and workflows.
