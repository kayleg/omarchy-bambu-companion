#pragma once

#include <algorithm>
#include <cmath>
#include <limits>

namespace Bambu {

constexpr float kFocusOccupancy = 0.5f;

struct Vec2 {
  float x;
  float y;
};

struct Bounds {
  float min_x;
  float max_x;
  float min_y;
  float max_y;
  float min_z;
  float max_z;
};

struct Projection {
  float scale;
  float center_u;
  float center_v;
  float yaw_cos;
  float yaw_sin;
  float pitch_cos;
  float pitch_sin;
  float model_center_x;
  float model_center_y;
  float model_center_z;
  float width;
  float height;
  float min_z;
  float explosion_progress;
  float explosion_factor;
};

inline float display_z(float z, float min_z, float progress, float factor) {
  if (!std::isfinite(z))
    return min_z;
  if (!std::isfinite(progress) || progress <= 0.0f)
    return z;
  progress = std::clamp(progress, 0.0f, 1.0f);
  const float scale = 1.0f + progress * factor;
  return min_z + (z - min_z) * scale;
}

inline float projection_scale(float width, float height, float padding,
                              const Bounds &bounds, float explosion_progress,
                              float explosion_factor) {
  const float max_display_z = display_z(bounds.max_z, bounds.min_z,
                                        explosion_progress, explosion_factor);
  const float half_x = (bounds.max_x - bounds.min_x) * 0.5f;
  const float half_y = (bounds.max_y - bounds.min_y) * 0.5f;
  const float half_z = (max_display_z - bounds.min_z) * 0.5f;
  const float radius = std::sqrt(half_x * half_x + half_y * half_y +
                                 half_z * half_z);
  const float safe_padding =
      std::max(0.0f, std::min(padding, std::min(width, height) * 0.5f - 1.0f));
  const float available_w = std::max(1.0f, width - safe_padding * 2.0f);
  const float available_h = std::max(1.0f, height - safe_padding * 2.0f);
  const float diameter = std::max(radius * 2.0f, 1e-9f);
  return std::min(available_w, available_h) / diameter;
}

inline bool viewing_from_below(float pitch) {
  return std::isfinite(pitch) && std::sin(pitch) > 0.0f;
}

inline bool valid_bounds(const Bounds &bounds) {
  return std::isfinite(bounds.min_x) && std::isfinite(bounds.max_x) &&
         std::isfinite(bounds.min_y) && std::isfinite(bounds.max_y) &&
         std::isfinite(bounds.min_z) && std::isfinite(bounds.max_z) &&
         bounds.max_x >= bounds.min_x && bounds.max_y >= bounds.min_y &&
         bounds.max_z >= bounds.min_z;
}

inline Projection
make_projection(float width, float height, float yaw, float pitch,
                float padding, float zoom, const Bounds &bounds,
                float explosion_progress, float explosion_factor,
                float focus_z = std::numeric_limits<float>::quiet_NaN(),
                const Bounds *focus_bounds = nullptr) {
  float fitted_scale = projection_scale(
      width, height, padding, bounds, explosion_progress, explosion_factor);
  const float safe_zoom = std::isfinite(zoom) && zoom > 0.0f ? zoom : 1.0f;
  const float max_display_z = display_z(bounds.max_z, bounds.min_z,
                                        explosion_progress, explosion_factor);
  const float model_center_z = (bounds.min_z + max_display_z) * 0.5f;
  float center_u = 0.0f;
  float center_v = 0.0f;
  const float progress = std::isfinite(explosion_progress)
                             ? std::clamp(explosion_progress, 0.0f, 1.0f)
                             : 0.0f;
  const bool have_focus_bounds = focus_bounds && valid_bounds(*focus_bounds);
  if (progress > 0.0f && have_focus_bounds) {
    const float layer_scale =
        projection_scale(width, height, padding, *focus_bounds, 0.0f, 0.0f) *
        kFocusOccupancy;
    if (std::isfinite(layer_scale) && layer_scale > 0.0f)
      fitted_scale += (layer_scale - fitted_scale) * progress;
  }
  if (progress > 0.0f && std::isfinite(focus_z)) {
    const float clamped_focus_z =
        std::clamp(focus_z, bounds.min_z, bounds.max_z);
    const float focus_x =
        have_focus_bounds ? (focus_bounds->min_x + focus_bounds->max_x) * 0.5f
                          : (bounds.min_x + bounds.max_x) * 0.5f;
    const float focus_y =
        have_focus_bounds ? (focus_bounds->min_y + focus_bounds->max_y) * 0.5f
                          : (bounds.min_y + bounds.max_y) * 0.5f;
    const float translated_x = focus_x - (bounds.min_x + bounds.max_x) * 0.5f;
    const float translated_y = focus_y - (bounds.min_y + bounds.max_y) * 0.5f;
    const float translated_z =
        display_z(clamped_focus_z, bounds.min_z, progress, explosion_factor) -
        model_center_z;
    const float yaw_cos = std::cos(yaw);
    const float yaw_sin = std::sin(yaw);
    const float rotated_x = translated_x * yaw_cos - translated_y * yaw_sin;
    const float rotated_y = translated_x * yaw_sin + translated_y * yaw_cos;
    const float pitch_sin = std::sin(pitch);
    const float pitch_cos = std::cos(pitch);
    const float pitched_z = rotated_y * pitch_sin + translated_z * pitch_cos;
    center_u = rotated_x * progress;
    center_v = -pitched_z * progress;
  }
  return Projection{fitted_scale * safe_zoom,
                    center_u,
                    center_v,
                    std::cos(yaw),
                    std::sin(yaw),
                    std::cos(pitch),
                    std::sin(pitch),
                    (bounds.min_x + bounds.max_x) * 0.5f,
                    (bounds.min_y + bounds.max_y) * 0.5f,
                    model_center_z,
                    width,
                    height,
                    bounds.min_z,
                    explosion_progress,
                    explosion_factor};
}

inline Vec2 project_point(const Projection &p, float x, float y, float z) {
  const float translated_x = x - p.model_center_x;
  const float translated_y = y - p.model_center_y;
  const float translated_z =
      display_z(z, p.min_z, p.explosion_progress, p.explosion_factor) -
      p.model_center_z;
  const float rotated_x = translated_x * p.yaw_cos - translated_y * p.yaw_sin;
  const float rotated_y = translated_x * p.yaw_sin + translated_y * p.yaw_cos;
  const float pitched_z = rotated_y * p.pitch_sin + translated_z * p.pitch_cos;
  return Vec2{p.width * 0.5f + (rotated_x - p.center_u) * p.scale,
              p.height * 0.5f + (-pitched_z - p.center_v) * p.scale};
}

} // namespace Bambu
