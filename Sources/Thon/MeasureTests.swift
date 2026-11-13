import Foundation
import CoreGraphics
import AppKit

/// Headless checks for the measure tool and the nm / Å display switch (`Thon --picktest`).
func testMeasureAndUnits(_ t: inout TestRun) {
    t.section("measure tool and length units")
    let near = { (a: String, b: String) in a == b }

    // formatting
    t.check(near(LengthUnits.format(angstroms: 66.237, useAngstroms: true), "66.2 Å"), "Å format < 100", LengthUnits.format(angstroms: 66.237, useAngstroms: true))
    t.check(near(LengthUnits.format(angstroms: 1234.5, useAngstroms: true), "1234 Å") || near(LengthUnits.format(angstroms: 1234.5, useAngstroms: true), "1235 Å"), "Å format ≥ 100")
    t.check(near(LengthUnits.format(angstroms: 66.237, useAngstroms: false), "6.62 nm"), "nm format", LengthUnits.format(angstroms: 66.237, useAngstroms: false))
    t.check(near(LengthUnits.format(angstroms: 1234, useAngstroms: false), "123 nm"), "nm format ≥ 100", LengthUnits.format(angstroms: 1234, useAngstroms: false))
    t.check(near(LengthUnits.format(angstroms: 25000, useAngstroms: false), "2.50 µm"), "µm in nm mode")
    t.check(near(LengthUnits.format(nm: 29, useAngstroms: true), "290 Å") && near(LengthUnits.format(nm: 29, useAngstroms: false), "29.0 nm"), "nm input in both units")
    t.check(LengthUnits.fromNm(2.5, angstroms: true) == 25 && LengthUnits.toNm(LengthUnits.fromNm(2.5, angstroms: true), angstroms: true) == 2.5, "nm ↔ Å conversion round trip")
    t.check(near(LengthUnits.scaleBarLabel(angstroms: 200, useAngstroms: false), "20 nm") && near(LengthUnits.scaleBarLabel(angstroms: 200, useAngstroms: true), "200 Å"), "scale bar labels")
    t.check(near(LengthUnits.scaleBarLabel(angstroms: 20000, useAngstroms: true), "20000 Å") && near(LengthUnits.scaleBarLabel(angstroms: 20000, useAngstroms: false), "2 µm"), "scale bar labels, large")

    // geometry: 3-4-5 triangle at 6.6237 Å/px
    let l = MeasureLine(a: CGPoint(x: 10, y: 10), b: CGPoint(x: 13, y: 14))
    t.check(abs(l.lengthPx - 5) < 1e-12, "length in px")
    t.check(abs((l.lengthA(pixelSizeA: 6.6237) ?? 0) - 33.1185) < 1e-9 && l.lengthA(pixelSizeA: nil) == nil, "length in Å, nil when uncalibrated")
    t.check(abs(MeasureLine(a: .zero, b: CGPoint(x: 1, y: 0)).angleDeg) < 1e-12 && abs(MeasureLine(a: .zero, b: CGPoint(x: 0, y: -1)).angleDeg - 90) < 1e-9, "angle: right = 0°, up = 90°")
    t.check(abs(l.distance(to: CGPoint(x: 10, y: 14)) - 2.4) < 1e-9 && abs(l.distance(to: CGPoint(x: 0, y: 10)) - 10) < 1e-9, "distance to segment (perpendicular, endpoint)")
    t.check(l.label(pixelSizeA: 10, useAngstroms: true) == "50.0 Å  ·  5.0 px" && l.label(pixelSizeA: 10, useAngstroms: false) == "5.00 nm  ·  5.0 px", "label in both units", l.label(pixelSizeA: 10, useAngstroms: false))
    t.check(l.label(pixelSizeA: nil, useAngstroms: false) == "5.0 px (uncalibrated)", "uncalibrated label")

    // interaction
    let m = MeasureState()
    m.setImage(key: "a.mrc")
    m.mouseDown(at: CGPoint(x: 100, y: 100), radiusPx: 5)
    m.mouseDragged(to: CGPoint(x: 160, y: 180), constrain: false)
    m.mouseUp(at: CGPoint(x: 160, y: 180), radiusPx: 5)
    t.check(m.lines.count == 1 && abs(m.lines[0].lengthPx - 100) < 1e-9 && m.selected == m.lines[0].id, "drag draws a line of length 100 px")
    m.mouseDown(at: CGPoint(x: 160, y: 182), radiusPx: 5)                 // grabs the far endpoint
    m.mouseDragged(to: CGPoint(x: 200, y: 100), constrain: false)
    m.mouseUp(at: CGPoint(x: 200, y: 100), radiusPx: 5)
    t.check(m.lines.count == 1 && abs(m.lines[0].a.x - 100) < 1e-9 && abs(m.lines[0].b.x - 200) < 1e-9 && abs(m.lines[0].lengthPx - 100) < 1e-9, "dragging an endpoint adjusts the line, no new line")
    m.mouseDown(at: CGPoint(x: 300, y: 300), radiusPx: 5); m.mouseUp(at: CGPoint(x: 300, y: 300), radiusPx: 5)
    t.check(m.lines.count == 1 && m.selected == nil, "click on empty space leaves no stray line and deselects")
    m.mouseDown(at: CGPoint(x: 150, y: 102), radiusPx: 5); m.mouseUp(at: CGPoint(x: 150, y: 102), radiusPx: 5)
    t.check(m.lines.count == 1 && m.selected == m.lines[0].id, "click on a line body selects it")
    // shift snaps to 45°, length is kept
    m.clear()
    m.mouseDown(at: CGPoint(x: 0, y: 0), radiusPx: 5); m.mouseDragged(to: CGPoint(x: 100, y: 12), constrain: true); m.mouseUp(at: CGPoint(x: 100, y: 12), radiusPx: 5)
    t.check(m.lines.count == 1 && abs(m.lines[0].b.y) < 1e-9 && abs(m.lines[0].lengthPx - hypot(100, 12)) < 1e-9, "shift snaps to horizontal")
    m.clear()
    m.mouseDown(at: CGPoint(x: 0, y: 0), radiusPx: 5); m.mouseDragged(to: CGPoint(x: 60, y: 50), constrain: true); m.mouseUp(at: CGPoint(x: 60, y: 50), radiusPx: 5)
    t.check(abs(m.lines[0].dx - m.lines[0].dy) < 1e-9, "shift snaps near-diagonal to 45°")
    // per-image memory
    m.setImage(key: "b.mrc")
    t.check(m.lines.isEmpty, "other image starts empty")
    m.setImage(key: "a.mrc")
    t.check(m.lines.count == 1, "lines come back with their image")
    // delete / right-click / keys
    m.enabled = true
    t.check(!m.handleKey(keyCode: 51), "delete with nothing selected falls through")
    m.mouseDown(at: CGPoint(x: 30, y: 25), radiusPx: 5); m.mouseUp(at: CGPoint(x: 30, y: 25), radiusPx: 5)
    t.check(m.selected != nil && m.handleKey(keyCode: 51) && m.lines.isEmpty, "select + delete removes the line")
    m.mouseDown(at: CGPoint(x: 0, y: 0), radiusPx: 5); m.mouseDragged(to: CGPoint(x: 50, y: 0), constrain: false); m.mouseUp(at: CGPoint(x: 50, y: 0), radiusPx: 5)
    m.rightClick(at: CGPoint(x: 25, y: 2), radiusPx: 5)
    t.check(m.lines.isEmpty, "right-click removes the line under the cursor")
    t.check(m.handleKey(keyCode: 53) && !m.enabled, "escape with no selection leaves the tool")

    // hold-Space peek key
    t.check(OverlayPeek.isPeekKey(keyCode: 49, modifiers: []) && OverlayPeek.isPeekKey(keyCode: 49, modifiers: [.shift]), "Space (with or without Shift) is the peek key")
    t.check(!OverlayPeek.isPeekKey(keyCode: 49, modifiers: [.command]) && !OverlayPeek.isPeekKey(keyCode: 49, modifiers: [.option]) && !OverlayPeek.isPeekKey(keyCode: 0, modifiers: []), "other keys and Command/Option+Space are not")
}
