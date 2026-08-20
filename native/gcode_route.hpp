#pragma once

#include "projection.hpp"

#include <QColor>
#include <QPointF>
#include <QQuickItem>
#include <QString>
#include <QVariant>
#include <cstddef>
#include <limits>
#include <vector>

class GcodeRoute : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QString segmentPath READ segmentPath WRITE setSegmentPath)
  Q_PROPERTY(QVariant bounds READ bounds WRITE setBounds)
  Q_PROPERTY(qreal yaw READ yaw WRITE setYaw NOTIFY yawChanged)
  Q_PROPERTY(qreal pitch READ pitch WRITE setPitch NOTIFY pitchChanged)
  Q_PROPERTY(qreal zoom READ zoom WRITE setZoom NOTIFY zoomChanged)
  Q_PROPERTY(qreal explosionProgress READ explosionProgress WRITE
                 setExplosionProgress NOTIFY explosionProgressChanged)
  Q_PROPERTY(qreal explosionFactor READ explosionFactor WRITE setExplosionFactor
                 NOTIFY explosionFactorChanged)
  Q_PROPERTY(qreal cutoffZ READ cutoffZ WRITE setCutoffZ NOTIFY cutoffZChanged)
  Q_PROPERTY(qreal padding READ padding WRITE setPadding NOTIFY paddingChanged)
  Q_PROPERTY(
      bool dragging READ dragging WRITE setDragging NOTIFY draggingChanged)
  Q_PROPERTY(QColor printedColor READ printedColor WRITE setPrintedColor NOTIFY
                 printedColorChanged)
  Q_PROPERTY(QColor remainingColor READ remainingColor WRITE setRemainingColor
                 NOTIFY remainingColorChanged)
  Q_PROPERTY(QColor plateColor READ plateColor WRITE setPlateColor NOTIFY
                 plateColorChanged)

public:
  explicit GcodeRoute(QQuickItem *parent = nullptr);

  QString segmentPath() const { return m_segmentPath; }
  QVariant bounds() const;
  void setSegmentPath(const QString &path);
  void setBounds(const QVariant &value);

  qreal yaw() const { return m_yaw; }
  qreal pitch() const { return m_pitch; }
  qreal zoom() const { return m_zoom; }
  qreal explosionProgress() const { return m_explosionProgress; }
  qreal explosionFactor() const { return m_explosionFactor; }
  qreal cutoffZ() const { return m_cutoffZ; }
  qreal padding() const { return m_padding; }
  bool dragging() const { return m_dragging; }
  QColor printedColor() const { return m_printedColor; }
  QColor remainingColor() const { return m_remainingColor; }
  QColor plateColor() const { return m_plateColor; }

  void setYaw(qreal yaw);
  void setPitch(qreal pitch);
  void setZoom(qreal zoom);
  void setExplosionProgress(qreal explosionProgress);
  void setExplosionFactor(qreal explosionFactor);
  void setCutoffZ(qreal cutoffZ);
  void setPadding(qreal padding);
  void setDragging(bool dragging);
  void setPrintedColor(const QColor &color);
  void setRemainingColor(const QColor &color);
  void setPlateColor(const QColor &color);

  Q_INVOKABLE QPointF mapToView(qreal x, qreal y, qreal z) const;
  Q_INVOKABLE QVariantList sampleNozzle(qreal z, qreal distance) const;

signals:
  void yawChanged();
  void pitchChanged();
  void zoomChanged();
  void explosionProgressChanged();
  void explosionFactorChanged();
  void cutoffZChanged();
  void paddingChanged();
  void draggingChanged();
  void printedColorChanged();
  void remainingColorChanged();
  void plateColorChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) override;

private:
  Bambu::Bounds derivedBounds() const;
  Bambu::Projection currentProjection() const;
  void invalidateNozzlePath();
  void rebuildNozzlePath(qreal z) const;

  std::vector<float> m_segments;
  QString m_segmentPath;
  Bambu::Bounds m_bounds{0.0f, 1.0f, 0.0f, 1.0f, 0.0f, 1.0f};
  bool m_haveExplicitBounds = false;
  bool m_geometryDirty = true;
  bool m_plateDirty = true;
  mutable bool m_nozzlePathDirty = true;
  mutable qreal m_nozzleTargetZ = std::numeric_limits<qreal>::quiet_NaN();
  mutable std::vector<std::size_t> m_nozzleSegmentOffsets;
  mutable std::vector<float> m_nozzleCumulativeLengths;
  mutable Bambu::Bounds m_focusLayerBounds{};
  mutable bool m_focusLayerBoundsValid = false;
  qreal m_yaw = 0.0;
  qreal m_pitch = -0.28;
  qreal m_zoom = 1.0;
  qreal m_explosionProgress = 0.0;
  qreal m_explosionFactor = 0.0;
  qreal m_cutoffZ = std::numeric_limits<qreal>::quiet_NaN();
  qreal m_padding = 0.0;
  bool m_dragging = false;
  QColor m_printedColor{255, 153, 51, qRound(0.74 * 255)};
  QColor m_remainingColor{255, 255, 255, qRound(0.10 * 255)};
  QColor m_plateColor{255, 255, 255, qRound(0.07 * 255)};
};
