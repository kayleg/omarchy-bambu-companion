# Demo model

The bundled G-code is a local, static showcase for the plugin's own preview
pipeline. It is never uploaded or sent to a printer and must not be used as a
printer-ready file.

`omarchy-logo.scad` builds a 170 × 47.5 × 10 mm plaque from the official MIT
licensed Omarchy wordmark. The dimensions fit the 180 × 180 mm build area of
the smallest supported Bambu Lab printer.

The source G-code was generated with OpenSCAD 2021.01 and PrusaSlicer 2.9.6:

```bash
openscad -o omarchy-logo.stl omarchy-logo.scad
prusa-slicer --export-gcode --output omarchy-logo.gcode \
  --bed-shape '0x0,180x0,180x180,0x180' --center 90,90 --skirts 0 \
  --layer-height 0.3 --first-layer-height 0.3 --perimeters 2 \
  --fill-density 15% omarchy-logo.stl
```

The committed asset retains only the ordered outer-wall moves consumed by the
preview parser. Removing temperatures, infill and other printer instructions
keeps the installation small and reinforces that this is a local visualization
fixture, not a printable file.

The OpenSCAD source converts SVG's downward Y axis to printer coordinates so
the wordmark is upright in the canonical G-code preview, with the plaque below
the raised letters.

The STL is an intermediate build artifact and is intentionally not committed.
