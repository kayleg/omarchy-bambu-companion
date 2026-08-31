#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

namespace Bambu {

inline bool unpack_little_endian_segments(const unsigned char *bytes,
                                          size_t byte_count,
                                          size_t max_segments,
                                          std::vector<float> *packed) {
  constexpr size_t kBytesPerSegment = 6 * sizeof(float);
  if (!bytes || !packed || byte_count == 0 ||
      byte_count % kBytesPerSegment != 0)
    return false;
  const size_t segment_count = byte_count / kBytesPerSegment;
  if (segment_count > max_segments)
    return false;

  std::vector<float> next;
  next.reserve(segment_count * 6);
  for (size_t offset = 0; offset < byte_count; offset += sizeof(float)) {
    const uint32_t bits = uint32_t(bytes[offset]) |
                          (uint32_t(bytes[offset + 1]) << 8) |
                          (uint32_t(bytes[offset + 2]) << 16) |
                          (uint32_t(bytes[offset + 3]) << 24);
    float value = 0.0f;
    static_assert(sizeof(value) == sizeof(bits));
    std::memcpy(&value, &bits, sizeof(value));
    if (!std::isfinite(value))
      return false;
    next.push_back(value);
  }
  *packed = std::move(next);
  return true;
}

// One byte per segment, written beside the packed floats. Anything the
// renderer does not recognise collapses to role 0 so a newer daemon cannot
// index past the colour table of an older build.
inline bool unpack_segment_roles(const unsigned char *bytes, size_t byte_count,
                                 size_t segment_count, size_t role_count,
                                 std::vector<unsigned char> *roles) {
  if (!roles)
    return false;
  if (!bytes || byte_count != segment_count)
    return false;

  std::vector<unsigned char> next;
  next.reserve(segment_count);
  for (size_t i = 0; i < byte_count; ++i)
    next.push_back(bytes[i] < role_count ? bytes[i] : 0);
  *roles = std::move(next);
  return true;
}

} // namespace Bambu
