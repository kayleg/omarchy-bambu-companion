// Derived from the MIT-licensed Omarchy wordmark shipped at
// /usr/share/omarchy/logo.svg.
svg_pixels_per_inch = 72;
millimeters_per_inch = 25.4;
logo_source_width = 1215 * millimeters_per_inch / svg_pixels_per_inch;
logo_source_height = 285 * millimeters_per_inch / svg_pixels_per_inch;
logo_width = 160;
logo_scale = logo_width / logo_source_width;
logo_depth = 8;
base_depth = 2;
margin = 5;

logo_size = [logo_width, logo_source_height * logo_scale];
base_size = [logo_size.x + margin * 2, logo_size.y + margin * 2];

union() {
  translate([-base_size.x / 2, -base_size.y / 2, 0])
    cube([base_size.x, base_size.y, base_depth]);

  // Convert SVG's downward Y axis to the printer's upward Y axis.
  translate([-logo_size.x / 2, logo_size.y / 2, base_depth])
    linear_extrude(height = logo_depth)
      scale([logo_scale, -logo_scale])
        import("omarchy-logo.svg");
}
