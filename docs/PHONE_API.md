# Thon phone swiper: API contract (v1)

The phone is a **remote control for Thon's swipe deck** (`SwipeSession`) on the micrograph that is open in the Mac app.
Thon stays the source of truth: every decision goes through `SwipeSession` / `PickStore`, so autosave, undo, stats, decoys and
the exported `.star` / `swipe_decisions.csv` behave exactly as when you swipe on the Mac. The phone never receives micrograph
data, only rendered card images (JPEG crops).

Scope: same Wi-Fi only, plain HTTP, no accounts. No native iOS app; the client is a web app served by Thon.

## Pairing and security

* The server only runs while the **Phone** panel's switch is on. It listens on a fixed, user-chosen port (default 8431).
* A random 128-bit **token** is generated once and kept in UserDefaults, so a home-screen icon keeps working across restarts.
  "Reset pairing" makes a new token (old phones stop working).
* Every request (pages, assets, API) must carry the token: query `?t=<token>`, header `X-Thon-Token`, or the cookie `thon_t`
  (set by the first page load). Wrong or missing token: `401`, no body.
* The web app's manifest is served with `start_url` = `/?t=<token>`, so the home-screen icon opens already paired.
* The API serves only card refs and the label scheme. No file paths, no directory listing. Request body limit 64 KB, header limit 16 KB.
* Traffic is unencrypted HTTP on the local network. Do not use on a network you do not trust (README states this).

## Identifiers

* **Level** = the micrograph open in Thon, identified by its project key (`PickStore.key(for:)`, e.g. `grid3/F4_017.mrc`).
* **Card ref** = `<level key>@<card id>` (same form as the web swiper's `swipe.json` ids). Card id is the pick id for real cards and `d<n>` for decoys.
* **Scheme revision** = stable hash of the label scheme JSON. **State revision** `rev` = counter that increases on any change visible to the phone.

## Endpoints

All responses are JSON (`Content-Type: application/json`) except pages and card images. Every POST returns the fresh state object.

### Pages and assets (GET)
`/`, `/app.js`, `/app.css`, `/manifest.webmanifest`, `/icon.png`.

### `GET /api/state`
```json
{
  "v": 1, "rev": 42,
  "project": {"name": "F4 grids"},
  "scheme": {"rev": "a1b2c3d4", "labels": [
      {"id": "good", "name": "Good", "key": "1", "color": "#4dff6a", "shape": "circle", "exported": true}]},
  "activeLabel": "good",
  "unsureLabel": "maybe",
  "level": {"key": "grid3/F4_017.mrc", "name": "F4_017.mrc", "index": 16, "count": 51,
            "total": 108, "reviewed": 12, "done": false, "loading": false,
            "candidates": 100, "autoBusy": false},
  "card": {"ref": "grid3/F4_017.mrc@k3x9a1bz", "diameterFrac": 0.21, "boxFrac": 0.56,
           "cross": [0.5, 0.5], "windowNm": 45.0, "view": "raw"},
  "upcoming": ["grid3/F4_017.mrc@m2q8c0de", "..."],
  "canUndo": true,
  "stats": {"level": {"cards": 12, "pick": 5, "reject": 6, "unsure": 1},
            "all": {"cards": 340, "pick": 120, "reject": 200, "unsure": 20,
                    "pickRateReal": 0.38, "pickRateDecoy": 0.0, "decoySeen": 25}}
}
```
* Whether a card is a decoy is deliberately never sent to the phone (decoys stay blind).
* `cross` is the marker position as fractions of the card ((0.5, 0.5) unless the card was recentered).
* `card` is `null` when the level is done, empty, or loading. `upcoming` lists up to 12 refs after the current card (for image prefetch).
* `diameterFrac` and `boxFrac` are marker diameter and extraction box as fractions of the card width, so the phone can draw the marker and box.
* `scheme.labels` contains **all** labels; the phone shows chips for `exported == true` ones, in project order, in the project's colours.
* `unsureLabel` is the label an up-swipe applies (`uncertain` if the scheme has it, else `maybe`); `null` means up = "later".

### `GET /api/card/<url-encoded ref>.jpg?out=480`
Grayscale JPEG of the card (`out` 128...800, default 480), same crop, window and smoothing as the Mac card. `404` if the ref is not in
the current deck (already decided, or another level). `Cache-Control: no-store`.

### `POST /api/decision`
```json
{"ref": "grid3/F4_017.mrc@k3x9a1bz", "decision": "pick", "label": "good", "u": 0.52, "v": 0.47, "ms": 1830, "cid": "p-7f3a"}
```
* `decision`: `pick` | `reject` | `unsure` | `later`.
* `label` (pick only): must be an exported label of the scheme, else the Mac's active label is used.
* `u`, `v` (optional, 0...1, top-left origin): recentered position as fractions of the card. Applied as `recenter` before the decision.
* `ms` dwell time, recorded as on the Mac. `cid` client decision id, for idempotent replay.
* If `ref` is not the current card but is still in the deck, it is moved to the front first (so offline replay in a different order still works).
* If `ref` was already decided (duplicate replay, or decided on the Mac), the response is `200` with `"applied": false, "reason": "already decided"`.
* If `ref` belongs to a different level than the one open in Thon: `409` with `"reason": "level changed"`; the phone drops the item and shows the new state.
* Decoys are logged only, never exported as picks (unchanged Thon behaviour).

Response: `{"applied": true|false, "reason": "...", "state": {...}}`.

### `POST /api/undo`
Undoes the last decision made in this session (`SwipeSession.undo`, which also undoes the pick edit). `applied: false` if nothing to undo.

### `POST /api/label` `{"id": "good"}`
Sets the Mac's active label (what a bare swipe-right applies). Unknown or non-exported id: `400`.

### `POST /api/level` `{"action": "next" | "prev" | "rebuild"}`
`next` / `prev` open the next/previous micrograph **that has candidate cards** (falls back to plain neighbour); the Mac loads it, and `level.loading`
is true until the deck is rebuilt. `rebuild` rebuilds the current deck. `409` when there is no further micrograph.

### `POST /api/autopick`
Runs the auto-picker on the open micrograph (same as the Mac's "Find particles"). Returns state with `level.autoBusy: true`.

### `GET /api/stats`
`{"level": {...}, "all": {...}}` as in state, plus `perLevel` (array of `{key, cards, pick, reject, unsure}`) for the stats page.

## Label scheme sync

The phone never stores a scheme. It re-reads `scheme` from every state response; when `scheme.rev` differs from what it renders, it rebuilds the
chips and colours. Editing labels on the Mac (label editor, preset, remap) therefore shows on the phone within one poll (2 s). A decision that names a
label the scheme no longer has falls back to the active label (response `reason: "label replaced"`).

## Offline behaviour (client)

The client keeps decisions it could not send in `localStorage` (ordered, with `cid`) and replays them when the connection returns; the server's
idempotent handling above makes replay safe. The queue shows as a badge. It is never silently dropped: items rejected with `409` are listed in the stats page.

## Concurrency rules

* One deck, owned by the Mac's `SwipeSession`. Mac and phone can both decide cards; whichever arrives first wins, the other gets `already decided`.
* Mac-side changes (undo in the Mac window, navigating to another micrograph, scheme edits) appear in the phone's next state poll.
* Requests are handled on the main thread (they touch `PickStore`); JPEG rendering runs off the main thread on one serial queue.

## Out of scope for v1

HTTPS / off-LAN access, multi-user, per-phone decks, native iOS app, editing picks (move/delete) from the phone.
