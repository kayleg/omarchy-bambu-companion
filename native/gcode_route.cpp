#include "gcode_route.hpp"

#include "segments.hpp"

#include <QDebug>
#include <QFile>
#include <QMatrix4x4>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGNode>
#include <QtMath>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace {

constexpr float kRouteLineWidth = 0.65f;
constexpr float kPlateLineWidth = 0.75f;
constexpr int kPlateDivisions = 8;
constexpr int kMaxSegments = 1'000'000;
constexpr size_t kNozzleSegmentBudget = 4096;
constexpr int kUniformFloats = 16 + 29;
constexpr int kUniformBytes = kUniformFloats * int(sizeof(float));

struct RouteVertex {
  float x0;
  float y0;
  float z0;
  float x1;
  float y1;
  float z1;
  float side;
  float endp;
  float posX;
  float posY;
};

// World mm stays in non-position attrs. Dummy item-space position is the
// scene-graph AABB so Qt does not cull when minY(mm) exceeds pane height(px).
const QSGGeometry::AttributeSet &routeAttributeSet() {
  static const QSGGeometry::Attribute attributes[] = {
      QSGGeometry::Attribute::create(0, 3, QSGGeometry::FloatType, false),
      QSGGeometry::Attribute::create(1, 3, QSGGeometry::FloatType, false),
      QSGGeometry::Attribute::create(2, 1, QSGGeometry::FloatType, false),
      QSGGeometry::Attribute::create(3, 1, QSGGeometry::FloatType, false),
      QSGGeometry::Attribute::create(4, 2, QSGGeometry::FloatType, true),
  };
  static const QSGGeometry::AttributeSet attributeSet = {
      5, int(sizeof(RouteVertex)), attributes};
  return attributeSet;
}

void writeSegment(RouteVertex *verts, float x0, float y0, float z0, float x1,
                  float y1, float z1) {
  static const float kSides[6] = {-1.0f, 1.0f, 1.0f, -1.0f, 1.0f, -1.0f};
  static const float kEnds[6] = {0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 1.0f};
  constexpr float kCullMax = 65535.0f;
  for (int i = 0; i < 6; ++i) {
    verts[i].x0 = x0;
    verts[i].y0 = y0;
    verts[i].z0 = z0;
    verts[i].x1 = x1;
    verts[i].y1 = y1;
    verts[i].z1 = z1;
    verts[i].side = kSides[i];
    verts[i].endp = kEnds[i];
    verts[i].posX = (kSides[i] < 0.0f) ? 0.0f : kCullMax;
    verts[i].posY = (kEnds[i] < 0.5f) ? 0.0f : kCullMax;
  }
}

void fillSegments(QSGGeometry *geometry, const std::vector<float> &packed) {
  const int segmentCount = int(packed.size() / 6);
  geometry->allocate(segmentCount * 6);
  if (segmentCount == 0)
    return;
  auto *verts = static_cast<RouteVertex *>(geometry->vertexData());
  for (size_t i = 0; i < size_t(segmentCount); ++i) {
    const size_t base = i * 6;
    writeSegment(verts + i * 6, packed[base], packed[base + 1],
                 packed[base + 2], packed[base + 3], packed[base + 4],
                 packed[base + 5]);
  }
  geometry->markVertexDataDirty();
}

void fillPlate(QSGGeometry *geometry, const Bambu::Bounds &bounds, bool hide) {
  const int lineCount = hide ? 0 : (kPlateDivisions + 1) * 2;
  geometry->allocate(lineCount * 6);
  if (lineCount == 0)
    return;
  auto *verts = static_cast<RouteVertex *>(geometry->vertexData());
  size_t line = 0;
  for (int step = 0; step <= kPlateDivisions; ++step) {
    const float t = float(step) / float(kPlateDivisions);
    const float x = bounds.min_x + (bounds.max_x - bounds.min_x) * t;
    const float y = bounds.min_y + (bounds.max_y - bounds.min_y) * t;
    writeSegment(verts + (line++) * 6, x, bounds.min_y, bounds.min_z, x,
                 bounds.max_y, bounds.min_z);
    writeSegment(verts + (line++) * 6, bounds.min_x, y, bounds.min_z,
                 bounds.max_x, y, bounds.min_z);
  }
  geometry->markVertexDataDirty();
}

QSGGeometry *ensureGeometry(QSGGeometryNode *node) {
  QSGGeometry *geometry = node->geometry();
  if (!geometry) {
    geometry = new QSGGeometry(routeAttributeSet(), 0);
    geometry->setDrawingMode(QSGGeometry::DrawTriangles);
    geometry->setVertexDataPattern(QSGGeometry::DynamicPattern);
    node->setGeometry(geometry);
    node->setFlag(QSGNode::OwnsGeometry, true);
  }
  return geometry;
}

class RouteMaterialShader : public QSGMaterialShader {
public:
  RouteMaterialShader() {
    setShaderFileName(
        VertexStage,
        QStringLiteral(":/io/github/ypmrg/bambu/gcode_route.vert.qsb"));
    setShaderFileName(
        FragmentStage,
        QStringLiteral(":/io/github/ypmrg/bambu/gcode_route.frag.qsb"));
  }

  bool updateUniformData(RenderState &state, QSGMaterial *newMaterial,
                         QSGMaterial *oldMaterial) override;
};

class RouteMaterial : public QSGMaterial {
public:
  RouteMaterial() {
    setFlag(Blending, true);
    setFlag(NoBatching, true);
  }

  QSGMaterialType *type() const override {
    static QSGMaterialType t;
    return &t;
  }

  QSGMaterialShader *
  createShader(QSGRendererInterface::RenderMode) const override {
    return new RouteMaterialShader;
  }

  void setProjection(const Bambu::Projection &p) { m_proj = p; }

  void setLineWidth(float lineWidth) { m_lineWidth = lineWidth; }

  void setCutoff(qreal cutoff, float maxZ) {
    m_cutoff = float(cutoff);
    m_cutoffValid = std::isfinite(cutoff) ? 1.0f : 0.0f;
    m_maxZ = maxZ;
  }

  void setColors(const QColor &printed, const QColor &remaining) {
    m_printed = printed;
    m_remaining = remaining;
  }

  Bambu::Projection m_proj{};
  float m_lineWidth = kRouteLineWidth;
  float m_cutoff = 0.0f;
  float m_cutoffValid = 0.0f;
  float m_maxZ = 1.0f;
  QColor m_printed{255, 153, 51, qRound(0.74 * 255)};
  QColor m_remaining{255, 255, 255, qRound(0.10 * 255)};
};

void writeColor(float *out, const QColor &color) {
  out[0] = float(color.redF());
  out[1] = float(color.greenF());
  out[2] = float(color.blueF());
  out[3] = float(color.alphaF());
}

bool RouteMaterialShader::updateUniformData(RenderState &state,
                                            QSGMaterial *newMaterial,
                                            QSGMaterial *oldMaterial) {
  Q_UNUSED(oldMaterial);
  QByteArray *buf = state.uniformData();
  if (!buf || buf->size() < kUniformBytes)
    return false;

  char *data = buf->data();

  if (state.isMatrixDirty()) {
    const QMatrix4x4 m = state.combinedMatrix();
    std::memcpy(data, m.constData(), 64);
  }

  float opacity = 1.0f;
  if (state.isOpacityDirty())
    opacity = state.opacity();
  else
    std::memcpy(&opacity, data + 64, 4);

  auto *mat = static_cast<RouteMaterial *>(newMaterial);
  const Bambu::Projection &p = mat->m_proj;
  const float dpr =
      state.devicePixelRatio() > 0.0f ? state.devicePixelRatio() : 1.0f;
  float tail[29] = {
      opacity,
      p.yaw_cos,
      p.yaw_sin,
      p.pitch_cos,
      p.pitch_sin,
      p.scale,
      p.center_u,
      p.center_v,
      p.width,
      p.height,
      mat->m_lineWidth,
      dpr,
      p.model_center_x,
      p.model_center_y,
      p.model_center_z,
      p.min_z,
      p.explosion_progress,
      p.explosion_factor,
      mat->m_cutoffValid > 0.5f ? mat->m_cutoff : 0.0f,
      mat->m_maxZ,
      mat->m_cutoffValid,
      0.0f,
      0.0f,
      0.0f,
      0.0f,
      0.0f,
      0.0f,
      0.0f,
      0.0f,
  };
  writeColor(tail + 21, mat->m_printed);
  writeColor(tail + 25, mat->m_remaining);
  std::memcpy(data + 64, tail, sizeof(tail));
  return true;
}

} // namespace

GcodeRoute::GcodeRoute(QQuickItem *parent) : QQuickItem(parent) {
  setFlag(ItemHasContents, true);
  setAntialiasing(false);
}

QVariant GcodeRoute::bounds() const {
  return QVariantMap{
      {QStringLiteral("minX"), m_bounds.min_x},
      {QStringLiteral("maxX"), m_bounds.max_x},
      {QStringLiteral("minY"), m_bounds.min_y},
      {QStringLiteral("maxY"), m_bounds.max_y},
      {QStringLiteral("minZ"), m_bounds.min_z},
      {QStringLiteral("maxZ"), m_bounds.max_z},
  };
}

void GcodeRoute::setSegmentPath(const QString &path) {
  if (path == m_segmentPath && !m_segments.empty())
    return;

  std::vector<float> next;
  bool loaded = false;
  QFile file(path);
  if (!path.isEmpty() && file.open(QIODevice::ReadOnly)) {
    const qint64 size = file.size();
    constexpr qint64 kBytesPerSegment = 6 * qint64(sizeof(float));
    constexpr qint64 kMaxBytes = qint64(kMaxSegments) * kBytesPerSegment;
    if (size > 0 && size <= kMaxBytes && size % kBytesPerSegment == 0) {
      const QByteArray bytes = file.readAll();
      loaded = bytes.size() == size &&
               Bambu::unpack_little_endian_segments(
                   reinterpret_cast<const unsigned char *>(bytes.constData()),
                   size_t(bytes.size()), size_t(kMaxSegments), &next);
    }
  }

  if (!loaded && !path.isEmpty())
    qWarning() << "bambu-route: rejected packed geometry" << path;
  const QString nextPath = loaded ? path : QString();
  if (nextPath == m_segmentPath && next == m_segments)
    return;
  m_segmentPath = nextPath;
  m_segments = std::move(next);
  if (!m_haveExplicitBounds)
    m_bounds = derivedBounds();
  invalidateNozzlePath();
  m_geometryDirty = true;
  m_plateDirty = true;
  update();
}

void GcodeRoute::setBounds(const QVariant &value) {
  const QVariantMap map = value.toMap();
  Bambu::Bounds next{};
  const auto read = [&map](const char *key, float *target) {
    bool converted = false;
    const double number = map.value(QLatin1String(key)).toDouble(&converted);
    if (!converted || !std::isfinite(number))
      return false;
    *target = float(number);
    return true;
  };
  const bool explicitBounds =
      read("minX", &next.min_x) && read("maxX", &next.max_x) &&
      read("minY", &next.min_y) && read("maxY", &next.max_y) &&
      read("minZ", &next.min_z) && read("maxZ", &next.max_z) &&
      Bambu::valid_bounds(next);
  if (!explicitBounds)
    next = derivedBounds();
  if (explicitBounds == m_haveExplicitBounds && next.min_x == m_bounds.min_x &&
      next.max_x == m_bounds.max_x && next.min_y == m_bounds.min_y &&
      next.max_y == m_bounds.max_y && next.min_z == m_bounds.min_z &&
      next.max_z == m_bounds.max_z) {
    return;
  }
  m_haveExplicitBounds = explicitBounds;
  m_bounds = next;
  m_plateDirty = true;
  update();
}

void GcodeRoute::setYaw(qreal yaw) {
  if (qFuzzyCompare(m_yaw, yaw))
    return;
  m_yaw = yaw;
  emit yawChanged();
  update();
}

void GcodeRoute::setPitch(qreal pitch) {
  if (qFuzzyCompare(m_pitch, pitch))
    return;
  m_pitch = pitch;
  emit pitchChanged();
  update();
}

void GcodeRoute::setZoom(qreal zoom) {
  if (qFuzzyCompare(m_zoom, zoom))
    return;
  m_zoom = zoom;
  emit zoomChanged();
  update();
}

void GcodeRoute::setExplosionProgress(qreal explosionProgress) {
  if (qFuzzyCompare(m_explosionProgress, explosionProgress))
    return;
  m_explosionProgress = explosionProgress;
  emit explosionProgressChanged();
  update();
}

void GcodeRoute::setExplosionFactor(qreal explosionFactor) {
  if (qFuzzyCompare(m_explosionFactor, explosionFactor))
    return;
  m_explosionFactor = explosionFactor;
  emit explosionFactorChanged();
  update();
}

void GcodeRoute::setCutoffZ(qreal cutoffZ) {
  if (qIsNaN(m_cutoffZ) && qIsNaN(cutoffZ))
    return;
  if (!qIsNaN(m_cutoffZ) && !qIsNaN(cutoffZ) &&
      qFuzzyCompare(m_cutoffZ, cutoffZ))
    return;
  m_cutoffZ = cutoffZ;
  emit cutoffZChanged();
  update();
}

void GcodeRoute::setPadding(qreal padding) {
  if (qFuzzyCompare(m_padding, padding))
    return;
  m_padding = padding;
  emit paddingChanged();
  update();
}

void GcodeRoute::setDragging(bool dragging) {
  if (m_dragging == dragging)
    return;
  m_dragging = dragging;
  m_plateDirty = true;
  emit draggingChanged();
  update();
}

void GcodeRoute::setPrintedColor(const QColor &color) {
  if (m_printedColor == color)
    return;
  m_printedColor = color;
  emit printedColorChanged();
  update();
}

void GcodeRoute::setRemainingColor(const QColor &color) {
  if (m_remainingColor == color)
    return;
  m_remainingColor = color;
  emit remainingColorChanged();
  update();
}

void GcodeRoute::setPlateColor(const QColor &color) {
  if (m_plateColor == color)
    return;
  m_plateColor = color;
  emit plateColorChanged();
  update();
}

QPointF GcodeRoute::mapToView(qreal x, qreal y, qreal z) const {
  const Bambu::Vec2 p =
      Bambu::project_point(currentProjection(), float(x), float(y), float(z));
  return QPointF(p.x, p.y);
}

void GcodeRoute::invalidateNozzlePath() {
  m_nozzlePathDirty = true;
  m_nozzleTargetZ = std::numeric_limits<qreal>::quiet_NaN();
  m_nozzleSegmentOffsets.clear();
  m_nozzleCumulativeLengths.clear();
  m_focusLayerBoundsValid = false;
}

void GcodeRoute::rebuildNozzlePath(qreal z) const {
  m_nozzlePathDirty = false;
  m_nozzleTargetZ = z;
  m_nozzleSegmentOffsets.clear();
  m_nozzleCumulativeLengths.clear();
  m_focusLayerBoundsValid = false;
  if (!std::isfinite(z) || m_segments.size() < 6)
    return;

  float nearestZ = 0.0f;
  float nearestDistance = std::numeric_limits<float>::infinity();
  for (size_t offset = 0; offset + 5 < m_segments.size(); offset += 6) {
    const float layerZ =
        (m_segments[offset + 2] + m_segments[offset + 5]) * 0.5f;
    const float distance = std::abs(layerZ - float(z));
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestZ = layerZ;
    }
  }
  if (!std::isfinite(nearestDistance))
    return;

  const float tolerance = std::max(1.0e-7f, std::abs(nearestZ) * 1.0e-9f);
  float totalLength = 0.0f;
  for (size_t offset = 0; offset + 5 < m_segments.size(); offset += 6) {
    const float layerZ =
        (m_segments[offset + 2] + m_segments[offset + 5]) * 0.5f;
    if (std::abs(layerZ - nearestZ) > tolerance)
      continue;

    for (size_t endpoint = 0; endpoint <= 3; endpoint += 3) {
      const float x = m_segments[offset + endpoint];
      const float y = m_segments[offset + endpoint + 1];
      const float endpointZ = m_segments[offset + endpoint + 2];
      if (!m_focusLayerBoundsValid) {
        m_focusLayerBounds = {x, x, y, y, endpointZ, endpointZ};
        m_focusLayerBoundsValid = true;
      } else {
        m_focusLayerBounds.min_x = std::min(m_focusLayerBounds.min_x, x);
        m_focusLayerBounds.max_x = std::max(m_focusLayerBounds.max_x, x);
        m_focusLayerBounds.min_y = std::min(m_focusLayerBounds.min_y, y);
        m_focusLayerBounds.max_y = std::max(m_focusLayerBounds.max_y, y);
        m_focusLayerBounds.min_z =
            std::min(m_focusLayerBounds.min_z, endpointZ);
        m_focusLayerBounds.max_z =
            std::max(m_focusLayerBounds.max_z, endpointZ);
      }
    }

    if (m_nozzleSegmentOffsets.size() >= kNozzleSegmentBudget)
      continue;
    const float dx = m_segments[offset + 3] - m_segments[offset];
    const float dy = m_segments[offset + 4] - m_segments[offset + 1];
    const float dz = m_segments[offset + 5] - m_segments[offset + 2];
    const float length = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (!std::isfinite(length) || length <= 0.0f)
      continue;
    totalLength += length;
    m_nozzleSegmentOffsets.push_back(offset);
    m_nozzleCumulativeLengths.push_back(totalLength);
  }
}

QVariantList GcodeRoute::sampleNozzle(qreal z, qreal phase) const {
  if (m_nozzlePathDirty || !std::isfinite(m_nozzleTargetZ) ||
      !qFuzzyCompare(m_nozzleTargetZ, z)) {
    rebuildNozzlePath(z);
  }
  if (m_nozzleSegmentOffsets.empty() || m_nozzleCumulativeLengths.empty())
    return {};

  qreal normalized = std::isfinite(phase) ? std::fmod(phase, 1.0) : 0.0;
  if (normalized < 0.0)
    normalized += 1.0;
  const float target = float(normalized) * m_nozzleCumulativeLengths.back();
  const auto begin = m_nozzleCumulativeLengths.cbegin();
  const auto end = m_nozzleCumulativeLengths.cend();
  const auto found = std::lower_bound(begin, end, target);
  const size_t index = found == end ? m_nozzleCumulativeLengths.size() - 1
                                    : size_t(found - begin);
  const size_t offset = m_nozzleSegmentOffsets[index];
  const float start = index == 0 ? 0.0f : m_nozzleCumulativeLengths[index - 1];
  const float length = m_nozzleCumulativeLengths[index] - start;
  const float ratio =
      length > 0.0f ? std::clamp((target - start) / length, 0.0f, 1.0f) : 0.0f;
  return {
      m_segments[offset] +
          (m_segments[offset + 3] - m_segments[offset]) * ratio,
      m_segments[offset + 1] +
          (m_segments[offset + 4] - m_segments[offset + 1]) * ratio,
      m_segments[offset + 2] +
          (m_segments[offset + 5] - m_segments[offset + 2]) * ratio,
  };
}

Bambu::Bounds GcodeRoute::derivedBounds() const {
  if (m_segments.size() < 6)
    return {0.0f, 1.0f, 0.0f, 1.0f, 0.0f, 1.0f};
  float min_x = m_segments[0];
  float max_x = m_segments[0];
  float min_y = m_segments[1];
  float max_y = m_segments[1];
  float min_z = m_segments[2];
  float max_z = m_segments[2];
  for (size_t i = 0; i + 5 < m_segments.size(); i += 6) {
    for (size_t k = 0; k < 6; k += 3) {
      min_x = std::min(min_x, m_segments[i + k]);
      max_x = std::max(max_x, m_segments[i + k]);
      min_y = std::min(min_y, m_segments[i + k + 1]);
      max_y = std::max(max_y, m_segments[i + k + 1]);
      min_z = std::min(min_z, m_segments[i + k + 2]);
      max_z = std::max(max_z, m_segments[i + k + 2]);
    }
  }
  return {min_x, max_x, min_y, max_y, min_z, max_z};
}

Bambu::Projection GcodeRoute::currentProjection() const {
  const Bambu::Bounds *focusBounds = nullptr;
  if (m_explosionProgress > 0.0 && std::isfinite(m_cutoffZ)) {
    if (m_nozzlePathDirty || !std::isfinite(m_nozzleTargetZ) ||
        !qFuzzyCompare(m_nozzleTargetZ, m_cutoffZ)) {
      rebuildNozzlePath(m_cutoffZ);
    }
    if (m_focusLayerBoundsValid)
      focusBounds = &m_focusLayerBounds;
  }
  return Bambu::make_projection(
      float(width()), float(height()), float(m_yaw), float(m_pitch),
      float(m_padding), float(m_zoom), m_bounds, float(m_explosionProgress),
      float(m_explosionFactor), float(m_cutoffZ), focusBounds);
}

QSGNode *GcodeRoute::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) {
  if (!std::isfinite(width()) || !std::isfinite(height()) || width() <= 0 ||
      height() <= 0)
    return oldNode;

  if (!oldNode) {
    m_geometryDirty = true;
    m_plateDirty = true;
  }

  QSGNode *root = oldNode;
  QSGGeometryNode *routeNode = nullptr;
  QSGGeometryNode *plateNode = nullptr;
  if (!root) {
    root = new QSGNode;
    plateNode = new QSGGeometryNode;
    plateNode->setFlag(QSGNode::OwnsMaterial, true);
    plateNode->setMaterial(new RouteMaterial);
    ensureGeometry(plateNode);
    root->appendChildNode(plateNode);

    routeNode = new QSGGeometryNode;
    routeNode->setFlag(QSGNode::OwnsMaterial, true);
    routeNode->setMaterial(new RouteMaterial);
    ensureGeometry(routeNode);
    root->appendChildNode(routeNode);
  } else {
    plateNode = static_cast<QSGGeometryNode *>(root->childAtIndex(0));
    routeNode = static_cast<QSGGeometryNode *>(root->childAtIndex(1));
  }

  if (m_geometryDirty) {
    fillSegments(ensureGeometry(routeNode), m_segments);
    routeNode->markDirty(QSGNode::DirtyGeometry);
    m_geometryDirty = false;
    m_plateDirty = true;
  }
  if (m_plateDirty) {
    const bool hidePlate = m_dragging || m_segments.size() < 6;
    fillPlate(ensureGeometry(plateNode), m_bounds, hidePlate);
    plateNode->markDirty(QSGNode::DirtyGeometry);
    m_plateDirty = false;
  }

  const Bambu::Projection proj = currentProjection();
  auto *routeMat = static_cast<RouteMaterial *>(routeNode->material());
  routeMat->setProjection(proj);
  routeMat->setLineWidth(kRouteLineWidth);
  routeMat->setCutoff(m_cutoffZ, m_bounds.max_z);
  routeMat->setColors(m_printedColor, m_remainingColor);
  routeNode->markDirty(QSGNode::DirtyMaterial);

  auto *plateMat = static_cast<RouteMaterial *>(plateNode->material());
  plateMat->setProjection(proj);
  plateMat->setLineWidth(kPlateLineWidth);
  plateMat->setCutoff(m_cutoffZ, m_bounds.max_z);
  plateMat->setColors(m_plateColor, m_plateColor);
  plateNode->markDirty(QSGNode::DirtyMaterial);

  return root;
}
