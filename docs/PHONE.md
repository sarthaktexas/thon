# Phone swiper

Swipe through the candidates of the micrograph open in Thon on your phone. The phone is a remote for Thon's swipe deck: every decision
goes through the same code as swiping on the Mac (picks, undo, autosave, decoys, statistics, export). No app to install; the phone
uses a web page that Thon serves while the Phone panel is switched on. The wire protocol is in [PHONE_API.md](PHONE_API.md).

## Use

1. On the Mac, open a micrograph that has candidates (Picks tab ▸ Find particles).
2. Picks ▸ **Phone Swiper…** (⌥⌘P), switch **Allow phone connections** on.
3. Phone and Mac on the same Wi-Fi: scan the QR code with the phone's Camera app. In Safari, Share ▸ Add to Home Screen keeps it as an app icon.
4. Swipe: right = pick, left = reject, up = unsure, down = later. Tap the card to recenter the cross. The chips above the card choose the label
   a right swipe applies. Undo (↶) undoes the last decision. ☰ opens stats and previous / next micrograph.

* Labels come from the open project's label scheme (Picks ▸ Edit Labels…). Edits on the Mac show on the phone within a few seconds.
* Up-swipe uses the scheme's `uncertain` label, or `maybe` in the Quality scheme; with neither it moves the card to the end.
* The card looks as it does in Thon's swipe mode (same display settings). About 8 % of cards are blind random-position decoys; the phone is
  never told which; the stats page shows your pick rate on them.
* If Wi-Fi drops, decisions are kept on the phone (badge "N to sync") and sent when it returns.
* Turn the switch off when you are done. **Reset pairing…** invalidates all phones paired before.

## Security

Plain HTTP on the local network; the pairing code in the link is the only protection. The server serves card images and the label scheme only
(no file paths) and runs only while the switch is on. Do not use it on a network you do not trust. Networks that isolate devices from each other
(some campus or guest Wi-Fi) block the connection; a phone hotspot that the Mac joins, or a VPN that puts both on one network, works.

## First-run checklist (needs a real phone)

1. Phone panel: switch on. macOS may ask to allow incoming connections: Allow. The panel shows a QR code and a link.
2. Phone: scan the code, allow the local-network prompt if iOS shows one. The page shows the micrograph name and the first card.
3. Swipe 20 cards (use all four directions). In Thon, the picks appear on the micrograph and `Picks ▸ Undo` reverts the last one.
4. Change the label scheme on the Mac; the chips change on the phone.
5. Switch Wi-Fi off on the phone for a few swipes, switch it on: the badge clears and Thon has the decisions.
6. Open ☰ ▸ Next micrograph; Thon opens the next micrograph that still has candidates.
7. Export picks; `swipe_decisions.csv` has the phone's decisions.

## Development

* Server: `Sources/Thon/Phone/` (`PhoneHTTP` parsing, `PhoneAPI` routing and logic, `PhoneServer` socket + pairing, `PhoneView` panel).
  `--picktest` has a "phone swiper API" suite that calls the handlers directly (no sockets).
* Web client: `Resources/phone/{index.html,app.css,app.js}`. It is embedded into `Sources/Thon/Phone/PhoneAssets.swift`; after editing run
  `python3 scripts/gen_phone_assets.py` (`--check` tells whether the generated file is current).
* Client logic tests: `cd Tests/phone && npm install jsdom && node client.test.js` (jsdom with a mock of the Mac API).
* Not covered by any test: the socket layer, QR scanning, layout and swipe feel on a phone, JPEG appearance.
