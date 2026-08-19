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

} // namespace Bambu
