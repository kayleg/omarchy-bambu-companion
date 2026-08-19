#include "projection.hpp"
#include "segments.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

int main() {
  using namespace Bambu;
  Bounds bounds{107.453f, 144.607f, 80.309f, 99.606f, 0.2f, 30.0f};
  const float collapsed = display_z(0.4f, 0.2f, 0.0f, 20.0f);
  const float halfway = display_z(0.4f, 0.2f, 0.5f, 20.0f);
  const float expanded = display_z(0.4f, 0.2f, 1.0f, 20.0f);
  const float base = display_z(0.2f, 0.2f, 1.0f, 20.0f);
  const float clamped = display_z(0.4f, 0.2f, 2.0f, 20.0f);

  const Projection fitted = make_projection(
      600, 360, kReferenceYaw, kReferencePitch, 24, 1.0f, bounds, 1.0f, 20.0f);
  float frame_left = std::numeric_limits<float>::infinity();
  float frame_right = -std::numeric_limits<float>::infinity();
  float frame_top = std::numeric_limits<float>::infinity();
  float frame_bottom = -std::numeric_limits<float>::infinity();
  for (int x_index = 0; x_index < 2; ++x_index) {
    const float x = x_index ? bounds.max_x : bounds.min_x;
    for (int y_index = 0; y_index < 2; ++y_index) {
      const float y = y_index ? bounds.max_y : bounds.min_y;
      for (int z_index = 0; z_index < 2; ++z_index) {
        const float z = z_index ? bounds.max_z : bounds.min_z;
        const Vec2 corner = project_point(fitted, x, y, z);
        frame_left = std::min(frame_left, corner.x);
        frame_right = std::max(frame_right, corner.x);
        frame_top = std::min(frame_top, corner.y);
        frame_bottom = std::max(frame_bottom, corner.y);
      }
    }
  }
  std::cout << "{\"displayZ\":[" << collapsed << "," << halfway << ","
            << expanded << "," << base << "," << clamped << "],\"frame\":{"
            << "\"scale\":" << fitted.scale << ",\"left\":" << frame_left
            << ",\"right\":" << frame_right << ",\"top\":" << frame_top
            << ",\"bottom\":" << frame_bottom << "}";
  Projection proj =
      make_projection(600, 360, 0, -0.28f, 24, 2.0f, bounds, 1.0f, 20.0f);
  const float mid_x = (bounds.min_x + bounds.max_x) * 0.5f;
  const float mid_y = (bounds.min_y + bounds.max_y) * 0.5f;
  const float mid_z = (bounds.min_z + bounds.max_z) * 0.5f;
  Vec2 zoomed = project_point(proj, mid_x, mid_y, mid_z);
  const float current_z = 4.2f;
  Projection focused = make_projection(600, 360, 0, -0.28f, 24, 8.0f, bounds,
                                       1.0f, 20.0f, current_z);
  Vec2 focused_layer = project_point(focused, mid_x, mid_y, current_z);
  const Bounds current_layer{112.0f, 140.0f,    84.0f,
                             96.0f,  current_z, current_z};
  const float explosion_factors[] = {0.0f, 20.0f, 500.0f};
  Projection upright_default =
      make_projection(600, 360, 0, -0.28f, 24, 1.0f, bounds, 0.0f, 20.0f);
  Vec2 upright_default_bottom =
      project_point(upright_default, mid_x, mid_y, bounds.min_z);
  Vec2 upright_default_top =
      project_point(upright_default, mid_x, mid_y, bounds.max_z);
  Projection upright_rotated =
      make_projection(600, 360, 1.1f, 0.55f, 24, 1.0f, bounds, 0.0f, 20.0f);
  Vec2 upright_rotated_bottom =
      project_point(upright_rotated, bounds.min_x, bounds.max_y, bounds.min_z);
  Vec2 upright_rotated_top =
      project_point(upright_rotated, bounds.min_x, bounds.max_y, bounds.max_z);
  const unsigned char little_endian[] = {
      0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x20, 0xc0, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x40, 0x40, 0x00, 0x00, 0x80, 0x40, 0x00, 0x00, 0xa0, 0x40};
  std::vector<float> decoded;
  const bool decoded_ok = unpack_little_endian_segments(
      little_endian, sizeof(little_endian), 1, &decoded);
  std::vector<float> rejected;
  const bool short_rejected = !unpack_little_endian_segments(
      little_endian, sizeof(little_endian) - 1, 1, &rejected);
  const bool limit_rejected = !unpack_little_endian_segments(
      little_endian, sizeof(little_endian), 0, &rejected);
  unsigned char nonfinite[sizeof(little_endian)];
  std::copy(little_endian, little_endian + sizeof(little_endian), nonfinite);
  nonfinite[0] = 0x00;
  nonfinite[1] = 0x00;
  nonfinite[2] = 0xc0;
  nonfinite[3] = 0x7f;
  const bool nonfinite_rejected = !unpack_little_endian_segments(
      nonfinite, sizeof(nonfinite), 1, &rejected);
  std::cout << ",\"zoomedCenter\":{\"x\":" << zoomed.x << ",\"y\":" << zoomed.y
            << "},\"focusedLayer\":{\"x\":" << focused_layer.x
            << ",\"y\":" << focused_layer.y << "},\"factorInvariantFocus\":[";
  for (int factor_index = 0; factor_index < 3; ++factor_index) {
    const float factor = explosion_factors[factor_index];
    const Projection layer_projection =
        make_projection(600, 360, 0, kReferencePitch, 24, 1.0f, bounds, 1.0f,
                        factor, current_z, &current_layer);
    const Vec2 layer_center = project_point(
        layer_projection, (current_layer.min_x + current_layer.max_x) * 0.5f,
        (current_layer.min_y + current_layer.max_y) * 0.5f, current_z);
    float min_x = std::numeric_limits<float>::infinity();
    float max_x = -std::numeric_limits<float>::infinity();
    float min_y = std::numeric_limits<float>::infinity();
    float max_y = -std::numeric_limits<float>::infinity();
    for (int x_index = 0; x_index < 2; ++x_index) {
      const float x = x_index ? current_layer.max_x : current_layer.min_x;
      for (int y_index = 0; y_index < 2; ++y_index) {
        const float y = y_index ? current_layer.max_y : current_layer.min_y;
        const Vec2 corner = project_point(layer_projection, x, y, current_z);
        min_x = std::min(min_x, corner.x);
        max_x = std::max(max_x, corner.x);
        min_y = std::min(min_y, corner.y);
        max_y = std::max(max_y, corner.y);
      }
    }
    const float occupancy = std::max((max_x - min_x) / (600.0f - 48.0f),
                                     (max_y - min_y) / (360.0f - 48.0f));
    if (factor_index)
      std::cout << ",";
    std::cout << "{\"factor\":" << factor
              << ",\"scale\":" << layer_projection.scale
              << ",\"centerX\":" << layer_center.x
              << ",\"centerY\":" << layer_center.y
              << ",\"occupancy\":" << occupancy << "}";
  }
  std::cout << "],\"uprightZ\":["
            << upright_default_top.x - upright_default_bottom.x << ","
            << upright_rotated_top.x - upright_rotated_bottom.x
            << "],\"binary\":{\"ok\":" << (decoded_ok ? "true" : "false")
            << ",\"shortRejected\":" << (short_rejected ? "true" : "false")
            << ",\"limitRejected\":" << (limit_rejected ? "true" : "false")
            << ",\"nonfiniteRejected\":"
            << (nonfinite_rejected ? "true" : "false") << ",\"values\":[";
  for (size_t i = 0; i < decoded.size(); ++i) {
    if (i)
      std::cout << ",";
    std::cout << decoded[i];
  }
  std::cout << "]}}\n";
  return 0;
}
