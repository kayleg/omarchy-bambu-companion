import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: viewport

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  property color neon: accent
  property color errorColor: Color.accent
  property bool errorActive: false
  property string fontFamily: Style.font.family
  property bool panelActive: false
  property bool daemonReady: false
  property bool printing: false
  property var activeSegments: []
  property var activeBounds: ({})
  property real zCurrent: NaN
  property string modelStatus: "idle"
  property string modelError: ""

  signal reloadRequested()

  readonly property color surface: Qt.rgba(
    foreground.r, foreground.g, foreground.b, 0.025)

  function coordinateOverlay() {
    var bounds = viewport.activeBounds || ({})
    var minX = Number(bounds.minX), maxX = Number(bounds.maxX)
    var minY = Number(bounds.minY), maxY = Number(bounds.maxY)
    var x = isFinite(minX) && isFinite(maxX) ? (minX + maxX) / 2 : NaN
    var y = isFinite(minY) && isFinite(maxY) ? (minY + maxY) / 2 : NaN
    return "X:" + (isFinite(x) ? x.toFixed(1) : "--")
      + "  Y:" + (isFinite(y) ? y.toFixed(1) : "--")
      + "  Z:" + (isFinite(viewport.zCurrent) ? viewport.zCurrent.toFixed(1) : "--")
  }

  function emptyModelTitle() {
    if (viewport.modelStatus === "loading") return "FINDING PRINT MODEL"
    if (viewport.printing && viewport.modelStatus === "error")
      return "MODEL NOT READY YET"
    if (viewport.printing) return "WAITING FOR PRINT MODEL"
    return "MODEL AVAILABLE DURING A PRINT"
  }

  function emptyModelDetail() {
    if (viewport.printing
        && (viewport.modelStatus === "loading" || viewport.modelStatus === "error")) {
      return "Automatic retries are limited · use Reload model to try again"
    }
    return ""
  }

  Rectangle {
    anchors.fill: parent
    color: viewport.surface
  }

  Rectangle {
    id: viewportHeader
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(36)
    color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                   viewport.foreground.b, 0.025)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                     viewport.foreground.b, 0.12)
    }

    Text {
      id: viewportTitle
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: "3D PRINT PREVIEW"
      color: viewport.foreground
      font.family: viewport.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Text {
      anchors.left: viewportTitle.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: "DRAG TO ROTATE · WHEEL TO ZOOM · HOLD TO PAUSE"
      color: viewport.dim
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      font.family: viewport.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Item {
    id: canvasFrame
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: viewportHeader.bottom
    anchors.bottom: parent.bottom
    clip: true

    Canvas {
      id: modelCanvas
      anchors.fill: parent
      renderStrategy: Canvas.Threaded

      property real yaw: 0
      property real pitch: -0.28
      property real zoom: 1
      property real wheelStepAccumulator: 0
      property bool autoRotate: true
      property bool dragging: false
      property real lastDragX: 0
      property real lastDragY: 0
      property double lastFrameTimestamp: 0
      property real frameScale: 1
      property real frameCenterU: 0
      property real frameCenterV: 0
      property real frameYawCosine: 1
      property real frameYawSine: 0
      property real framePitchCosine: 1
      property real framePitchSine: 0
      property real frameModelCenterX: 0
      property real frameModelCenterY: 0
      property real frameModelCenterZ: 0
      readonly property int motionSegmentBudget: 10000
      readonly property int stillSegmentBudget: 40000
      property real projectionMinX: 0
      property real projectionMaxX: 1
      property real projectionMinY: 0
      property real projectionMaxY: 1
      property real projectionMinZ: 0
      property real projectionMaxZ: 1

      function segmentIsFinite(segment) {
        if (!Array.isArray(segment) || segment.length !== 6) return false
        for (var coordinate = 0; coordinate < 6; coordinate++) {
          if (typeof segment[coordinate] !== "number"
              || !isFinite(segment[coordinate])) return false
        }
        return true
      }

      function renderBudget() {
        return dragging || autoRotate ? motionSegmentBudget : stillSegmentBudget
      }

      function renderCount() {
        return Math.min(viewport.activeSegments.length, renderBudget())
      }

      function segmentIndexForSample(sample, segmentCount, sampleCount) {
        if (segmentCount <= 1 || sampleCount <= 1) return 0
        return Math.round(sample * (segmentCount - 1) / (sampleCount - 1))
      }

      function normalizeAngle(value) {
        var turn = Math.PI * 2
        var normalized = value % turn
        return normalized < 0 ? normalized + turn : normalized
      }

      function clampPitch(value) {
        var limit = Math.PI / 2 - 0.05
        return Math.max(-limit, Math.min(limit, value))
      }

      function orientationAfterDrag(startYaw, startPitch, deltaX, deltaY,
                                    viewportWidth, viewportHeight) {
        if (!isFinite(viewportWidth) || viewportWidth <= 0
            || !isFinite(viewportHeight) || viewportHeight <= 0) {
          return { yaw: normalizeAngle(startYaw), pitch: clampPitch(startPitch) }
        }
        return {
          yaw: normalizeAngle(startYaw + deltaX / viewportWidth * Math.PI * 2),
          pitch: clampPitch(startPitch + deltaY / viewportHeight * Math.PI)
        }
      }

      function wheelStepDelta(angleDeltaY, pixelDeltaY) {
        var angle = Number(angleDeltaY)
        var pixel = Number(pixelDeltaY)
        if (isFinite(angle) && angle !== 0) return angle / 120
        return isFinite(pixel) ? pixel / 30 : 0
      }

      function wholeWheelSteps(accumulatedSteps) {
        var accumulated = Number(accumulatedSteps)
        if (!isFinite(accumulated)) return 0
        return accumulated < 0 ? Math.ceil(accumulated) : Math.floor(accumulated)
      }

      function zoomAfterSteps(currentZoom, steps) {
        var current = Number(currentZoom)
        if (!isFinite(current) || current <= 0) current = 1
        var wholeSteps = Number(steps)
        if (!isFinite(wholeSteps)) wholeSteps = 0
        var nextZoom = current * Math.pow(1.12, wholeSteps)
        return Math.max(0.5, Math.min(4, nextZoom))
      }

      function formatZoom(value) {
        var number = Number(value)
        if (!isFinite(number) || number <= 0 || Math.abs(number - 1) < 0.000001)
          return "1"
        return number.toFixed(2).replace(/\.?0+$/, "")
      }

      function advanceAutoRotation(timestamp) {
        var now = Number(timestamp)
        if (!isFinite(now)) return false
        if (lastFrameTimestamp <= 0) {
          lastFrameTimestamp = now
          return false
        }
        var elapsed = Math.max(0, Math.min(250, now - lastFrameTimestamp))
        lastFrameTimestamp = now
        if (dragging || !autoRotate) return false
        yaw = normalizeAngle(yaw + elapsed / 14000 * Math.PI * 2)
        requestPaint()
        return true
      }

      function rebuildProjectionBounds() {
        var bounds = viewport.activeBounds || ({})
        var supplied = typeof bounds.minX === "number" && isFinite(bounds.minX)
          && typeof bounds.maxX === "number" && isFinite(bounds.maxX)
          && typeof bounds.minY === "number" && isFinite(bounds.minY)
          && typeof bounds.maxY === "number" && isFinite(bounds.maxY)
          && typeof bounds.minZ === "number" && isFinite(bounds.minZ)
          && typeof bounds.maxZ === "number" && isFinite(bounds.maxZ)
          && bounds.minX <= bounds.maxX && bounds.minY <= bounds.maxY
          && bounds.minZ <= bounds.maxZ
        var minX = supplied ? bounds.minX : NaN
        var maxX = supplied ? bounds.maxX : NaN
        var minY = supplied ? bounds.minY : NaN
        var maxY = supplied ? bounds.maxY : NaN
        var minZ = supplied ? bounds.minZ : NaN
        var maxZ = supplied ? bounds.maxZ : NaN
        if (!supplied) {
          for (var index = 0; index < viewport.activeSegments.length; index++) {
            var segment = viewport.activeSegments[index]
            if (!segmentIsFinite(segment)) continue
            for (var endpoint = 0; endpoint <= 3; endpoint += 3) {
              var x = segment[endpoint]
              var y = segment[endpoint + 1]
              var z = segment[endpoint + 2]
              minX = isFinite(minX) ? Math.min(minX, x) : x
              maxX = isFinite(maxX) ? Math.max(maxX, x) : x
              minY = isFinite(minY) ? Math.min(minY, y) : y
              maxY = isFinite(maxY) ? Math.max(maxY, y) : y
              minZ = isFinite(minZ) ? Math.min(minZ, z) : z
              maxZ = isFinite(maxZ) ? Math.max(maxZ, z) : z
            }
          }
        }
        projectionMinX = isFinite(minX) ? minX : 0
        projectionMaxX = isFinite(maxX) ? maxX : 1
        projectionMinY = isFinite(minY) ? minY : 0
        projectionMaxY = isFinite(maxY) ? maxY : 1
        projectionMinZ = isFinite(minZ) ? minZ : 0
        projectionMaxZ = isFinite(maxZ) ? maxZ : 1
      }

      function projectionFrame(viewportWidth, viewportHeight, yawAngle, pitchAngle, padding) {
        var centerX = (projectionMinX + projectionMaxX) / 2
        var centerY = (projectionMinY + projectionMaxY) / 2
        var centerZ = (projectionMinZ + projectionMaxZ) / 2
        var yawCosine = Math.cos(yawAngle)
        var yawSine = Math.sin(yawAngle)
        var pitchCosine = Math.cos(pitchAngle)
        var pitchSine = Math.sin(pitchAngle)
        var minU = Infinity, maxU = -Infinity
        var minV = Infinity, maxV = -Infinity
        for (var xIndex = 0; xIndex < 2; xIndex++) {
          var x = (xIndex ? projectionMaxX : projectionMinX) - centerX
          for (var yIndex = 0; yIndex < 2; yIndex++) {
            var y = (yIndex ? projectionMaxY : projectionMinY) - centerY
            var rotatedX = x * yawCosine - y * yawSine
            var rotatedY = x * yawSine + y * yawCosine
            for (var zIndex = 0; zIndex < 2; zIndex++) {
              var z = (zIndex ? projectionMaxZ : projectionMinZ) - centerZ
              var pitchedY = rotatedY * pitchCosine - z * pitchSine
              var pitchedZ = rotatedY * pitchSine + z * pitchCosine
              var u = rotatedX - pitchedY * 0.34
              var v = -pitchedZ * 0.82 + pitchedY * 0.38
              minU = Math.min(minU, u)
              maxU = Math.max(maxU, u)
              minV = Math.min(minV, v)
              maxV = Math.max(maxV, v)
            }
          }
        }
        var safePadding = Math.max(0, Math.min(padding,
          Math.min(viewportWidth, viewportHeight) / 2 - 1))
        var availableWidth = Math.max(1, viewportWidth - safePadding * 2)
        var availableHeight = Math.max(1, viewportHeight - safePadding * 2)
        var spanU = Math.max(maxU - minU, 1e-9)
        var spanV = Math.max(maxV - minV, 1e-9)
        var scale = Math.min(availableWidth / spanU, availableHeight / spanV)
        var centerU = (minU + maxU) / 2
        var centerV = (minV + maxV) / 2
        return {
          scale: scale, centerU: centerU, centerV: centerV,
          left: viewportWidth / 2 + (minU - centerU) * scale,
          right: viewportWidth / 2 + (maxU - centerU) * scale,
          top: viewportHeight / 2 + (minV - centerV) * scale,
          bottom: viewportHeight / 2 + (maxV - centerV) * scale
        }
      }

      function prepareFrameProjection() {
        var padding = Math.max(Style.space(12), Math.min(width, height) * 0.07)
        var frame = projectionFrame(width, height, yaw, pitch, padding)
        frameScale = frame.scale * zoom
        frameCenterU = frame.centerU
        frameCenterV = frame.centerV
        frameYawCosine = Math.cos(yaw)
        frameYawSine = Math.sin(yaw)
        framePitchCosine = Math.cos(pitch)
        framePitchSine = Math.sin(pitch)
        frameModelCenterX = (projectionMinX + projectionMaxX) / 2
        frameModelCenterY = (projectionMinY + projectionMaxY) / 2
        frameModelCenterZ = (projectionMinZ + projectionMaxZ) / 2
      }

      function appendProjectedPoint(context, x, y, z, move) {
        var translatedX = x - frameModelCenterX
        var translatedY = y - frameModelCenterY
        var translatedZ = z - frameModelCenterZ
        var rotatedX = translatedX * frameYawCosine - translatedY * frameYawSine
        var rotatedY = translatedX * frameYawSine + translatedY * frameYawCosine
        var pitchedY = rotatedY * framePitchCosine - translatedZ * framePitchSine
        var pitchedZ = rotatedY * framePitchSine + translatedZ * framePitchCosine
        var u = rotatedX - pitchedY * 0.34
        var v = -pitchedZ * 0.82 + pitchedY * 0.38
        var screenX = width / 2 + (u - frameCenterU) * frameScale
        var screenY = height / 2 + (v - frameCenterV) * frameScale
        if (move) context.moveTo(screenX, screenY)
        else context.lineTo(screenX, screenY)
      }

      function appendWholeSegment(context, segment) {
        appendProjectedPoint(context, segment[0], segment[1], segment[2], true)
        appendProjectedPoint(context, segment[3], segment[4], segment[5], false)
      }

      function splitAtCut(context, segment, cutoff, brightWanted) {
        if (!isFinite(cutoff)) {
          if (brightWanted) return false
          appendWholeSegment(context, segment)
          return true
        }
        var firstX = segment[0], firstY = segment[1], firstZ = segment[2]
        var secondX = segment[3], secondY = segment[4], secondZ = segment[5]
        var firstBelow = firstZ <= cutoff
        var secondBelow = secondZ <= cutoff
        if (firstBelow === secondBelow) {
          if (firstBelow !== brightWanted) return false
          appendWholeSegment(context, segment)
          return true
        }
        var denominator = secondZ - firstZ
        var ratio = (cutoff - firstZ) / denominator
        ratio = Math.max(0, Math.min(1, ratio))
        var crossingX = firstX + (secondX - firstX) * ratio
        var crossingY = firstY + (secondY - firstY) * ratio
        if (firstBelow === brightWanted) {
          appendProjectedPoint(context, firstX, firstY, firstZ, true)
          appendProjectedPoint(context, crossingX, crossingY, cutoff, false)
        } else {
          appendProjectedPoint(context, crossingX, crossingY, cutoff, true)
          appendProjectedPoint(context, secondX, secondY, secondZ, false)
        }
        return true
      }

      function drawBuildPlateGrid(context) {
        if (viewport.activeSegments.length === 0) return
        var divisions = 8
        context.beginPath()
        for (var step = 0; step <= divisions; step++) {
          var ratio = step / divisions
          var x = projectionMinX + (projectionMaxX - projectionMinX) * ratio
          var y = projectionMinY + (projectionMaxY - projectionMinY) * ratio
          appendProjectedPoint(context, x, projectionMinY, projectionMinZ, true)
          appendProjectedPoint(context, x, projectionMaxY, projectionMinZ, false)
          appendProjectedPoint(context, projectionMinX, y, projectionMinZ, true)
          appendProjectedPoint(context, projectionMaxX, y, projectionMinZ, false)
        }
        context.lineWidth = 0.5
        context.strokeStyle = Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                                      viewport.foreground.b, 0.07)
        context.stroke()
      }

      function drawSegments(context, brightWanted, color, widthValue) {
        var cutoff = isFinite(viewport.zCurrent) ? viewport.zCurrent : NaN
        var countToDraw = renderCount()
        var drewSegment = false
        context.beginPath()
        for (var sample = 0; sample < countToDraw; sample++) {
          var index = segmentIndexForSample(
            sample, viewport.activeSegments.length, countToDraw)
          var segment = viewport.activeSegments[index]
          if (!segmentIsFinite(segment)) continue
          if (splitAtCut(context, segment, cutoff, brightWanted)) drewSegment = true
        }
        if (!drewSegment) return
        context.lineWidth = widthValue
        context.strokeStyle = color
        context.lineCap = "round"
        context.stroke()
      }

      function requestVisiblePaint(rebuildBounds) {
        if (!viewport.panelActive) return false
        if (rebuildBounds) rebuildProjectionBounds()
        requestPaint()
        return true
      }

      function drawFrame(context) {
        var renderColor = viewport.errorActive ? viewport.errorColor : viewport.neon
        var darkColor = Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                                viewport.foreground.b, 0.10)
        var completedColor = Qt.rgba(renderColor.r, renderColor.g,
                                     renderColor.b, 0.74)
        if (!isFinite(viewport.zCurrent) || viewport.zCurrent < projectionMinZ) {
          drawSegments(context, false, darkColor, 0.55)
          return
        }
        if (viewport.zCurrent >= projectionMaxZ) {
          drawSegments(context, true, completedColor, 0.70)
          return
        }
        drawSegments(context, false, darkColor, 0.55)
        drawSegments(context, true, completedColor, 0.70)
      }

      onPaint: {
        if (!viewport.panelActive) return
        if (!isFinite(width) || !isFinite(height) || width <= 0 || height <= 0) return
        prepareFrameProjection()
        var context = getContext("2d")
        context.reset()
        context.fillStyle = Qt.rgba(0, 0, 0, 0.20)
        context.fillRect(0, 0, width, height)
        drawBuildPlateGrid(context)
        drawFrame(context)
      }

      onWidthChanged: requestVisiblePaint(false)
      onHeightChanged: requestVisiblePaint(false)
      Component.onCompleted: requestVisiblePaint(true)
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      onWheel: function(wheel) {
        modelCanvas.wheelStepAccumulator += modelCanvas.wheelStepDelta(
          wheel.angleDelta ? wheel.angleDelta.y : 0,
          wheel.pixelDelta ? wheel.pixelDelta.y : 0)
        var wholeSteps = modelCanvas.wholeWheelSteps(modelCanvas.wheelStepAccumulator)
        if (wholeSteps !== 0) {
          modelCanvas.zoom = modelCanvas.zoomAfterSteps(modelCanvas.zoom, wholeSteps)
          modelCanvas.wheelStepAccumulator -= wholeSteps
          modelCanvas.requestPaint()
        }
        wheel.accepted = true
      }
      onPressed: function(mouse) {
        modelCanvas.dragging = true
        modelCanvas.lastDragX = mouse.x
        modelCanvas.lastDragY = mouse.y
        modelCanvas.lastFrameTimestamp = Date.now()
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var orientation = modelCanvas.orientationAfterDrag(
          modelCanvas.yaw, modelCanvas.pitch,
          mouse.x - modelCanvas.lastDragX, mouse.y - modelCanvas.lastDragY,
          width, height)
        modelCanvas.yaw = orientation.yaw
        modelCanvas.pitch = orientation.pitch
        modelCanvas.lastDragX = mouse.x
        modelCanvas.lastDragY = mouse.y
        modelCanvas.requestPaint()
      }
      onReleased: {
        modelCanvas.dragging = false
        modelCanvas.lastFrameTimestamp = Date.now()
        if (!modelCanvas.autoRotate) modelCanvas.requestPaint()
      }
      onCanceled: {
        modelCanvas.dragging = false
        modelCanvas.lastFrameTimestamp = Date.now()
        if (!modelCanvas.autoRotate) modelCanvas.requestPaint()
      }
    }

    Timer {
      interval: 50
      repeat: true
      running: viewport.panelActive && viewport.activeSegments.length > 0
        && modelCanvas.autoRotate
      onTriggered: modelCanvas.advanceAutoRotation(Date.now())
    }

    Row {
      id: modelControls
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      width: Math.max(0, Math.min(Style.space(290),
        coordinateBadge.visible
          ? coordinateBadge.x - x - Style.space(10)
          : parent.width - x - Style.space(10)))
      height: Style.space(30)
      spacing: Style.space(8)

      BambuButton {
        id: rotationButton
        width: Math.max(0, (modelControls.width - modelControls.spacing) / 2)
        height: modelControls.height
        clip: true
        text: modelCanvas.autoRotate ? "AUTO-ROTATE ON" : "AUTO-ROTATE OFF"
        foreground: modelCanvas.autoRotate ? viewport.neon : viewport.foreground
        accent: viewport.accent
        bordered: true
        onClicked: {
          modelCanvas.autoRotate = !modelCanvas.autoRotate
          modelCanvas.lastFrameTimestamp = Date.now()
          modelCanvas.requestPaint()
        }
      }

      BambuButton {
        id: reloadButton
        width: Math.max(0, (modelControls.width - modelControls.spacing) / 2)
        height: modelControls.height
        clip: true
        enabled: viewport.daemonReady
        text: "RELOAD MODEL"
        foreground: viewport.foreground
        accent: viewport.accent
        bordered: true
        onClicked: viewport.reloadRequested()
      }
    }

    Rectangle {
      id: coordinateBadge
      visible: canvasFrame.width >= Style.space(480)
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      width: coordinateText.implicitWidth + Style.space(12)
      height: Style.space(30)
      color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                     viewport.foreground.b, 0.045)
      border.width: 1
      border.color: Qt.rgba(viewport.foreground.r, viewport.foreground.g,
                            viewport.foreground.b, 0.12)
      Text {
        id: coordinateText
        anchors.centerIn: parent
        text: viewport.coordinateOverlay()
        color: viewport.dim
        font.family: viewport.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: modelFooter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(10)
      width: Math.max(0, parent.width - Style.space(20))
      height: Style.space(18)
      spacing: Style.space(6)
      clip: true
      readonly property real cellWidth: Math.max(0,
        (width - spacing * 2) / 3)

      Item {
        width: modelFooter.cellWidth
        height: modelFooter.height
        clip: true
        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)
          Text {
            text: "● PRINTED"
            color: viewport.errorActive ? viewport.errorColor : viewport.neon
            font.family: viewport.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            text: "● REMAINING"
            color: viewport.dim
            font.family: viewport.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        width: modelFooter.cellWidth
        height: modelFooter.height
        text: "ZOOM ×" + modelCanvas.formatZoom(modelCanvas.zoom)
        color: viewport.dim
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: viewport.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        width: modelFooter.cellWidth
        height: modelFooter.height
        text: "Z " + (isFinite(viewport.zCurrent)
          ? viewport.zCurrent.toFixed(2) + " mm" : "--")
        color: viewport.errorActive ? viewport.errorColor : viewport.neon
        elide: Text.ElideLeft
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        font.family: viewport.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(30)
      width: Math.max(0, parent.width - Style.space(40))
      text: viewport.modelError
      color: viewport.errorColor
      visible: viewport.modelError !== ""
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: viewport.fontFamily
      font.pixelSize: Style.font.caption
    }

    Column {
      anchors.centerIn: parent
      width: Math.max(0, parent.width - Style.space(48))
      spacing: Style.space(5)
      visible: viewport.activeSegments.length === 0

      Text {
        width: parent.width
        text: viewport.emptyModelTitle()
        color: viewport.errorActive ? viewport.errorColor : viewport.dim
        horizontalAlignment: Text.AlignHCenter
        font.family: viewport.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        width: parent.width
        text: viewport.emptyModelDetail()
        visible: text !== ""
        color: viewport.dim
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        font.family: viewport.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  onActiveSegmentsChanged: modelCanvas.requestVisiblePaint(true)
  onActiveBoundsChanged: modelCanvas.requestVisiblePaint(true)
  onZCurrentChanged: modelCanvas.requestVisiblePaint(false)
  onNeonChanged: modelCanvas.requestVisiblePaint(false)
  onErrorActiveChanged: modelCanvas.requestVisiblePaint(false)
  onErrorColorChanged: modelCanvas.requestVisiblePaint(false)
  onPanelActiveChanged: {
    modelCanvas.lastFrameTimestamp = 0
    if (viewport.panelActive) modelCanvas.requestVisiblePaint(true)
  }
}
