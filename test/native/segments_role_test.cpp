#include "segments.hpp"

#include <iostream>
#include <vector>

namespace {

int failures = 0;

void check(bool ok, const char *what) {
  if (!ok) {
    std::cout << "FAIL " << what << "\n";
    ++failures;
  }
}

} // namespace

int main() {
  using Bambu::unpack_segment_roles;
  std::vector<unsigned char> roles;

  // One byte per segment, kept in order.
  const unsigned char good[] = {0, 3, 2, 1};
  check(unpack_segment_roles(good, 4, 4, 5, &roles), "accepts a matching sidecar");
  check(roles == std::vector<unsigned char>({0, 3, 2, 1}), "preserves role order");

  // A sidecar that does not cover the geometry exactly must be refused: a
  // short read would colour segments by an off-by-one index.
  roles.clear();
  check(!unpack_segment_roles(good, 4, 5, 5, &roles), "rejects a short sidecar");
  check(!unpack_segment_roles(good, 4, 3, 5, &roles), "rejects a long sidecar");
  check(!unpack_segment_roles(nullptr, 0, 0, 5, &roles), "rejects a null sidecar");

  // A newer daemon may know roles this build does not; those must fold to 0
  // rather than index past the colour table.
  const unsigned char future[] = {0, 5, 9, 200};
  roles.clear();
  check(unpack_segment_roles(future, 4, 4, 5, &roles), "accepts unknown roles");
  check(roles == std::vector<unsigned char>({0, 0, 0, 0}),
        "clamps unknown roles to the wall colour");

  // The boundary itself: role_count - 1 is valid, role_count is not.
  const unsigned char edge[] = {4, 5};
  roles.clear();
  check(unpack_segment_roles(edge, 2, 2, 5, &roles), "accepts the boundary");
  check(roles == std::vector<unsigned char>({4, 0}), "keeps 4, folds 5");

  if (failures == 0)
    std::cout << "OK\n";
  return failures == 0 ? 0 : 1;
}
