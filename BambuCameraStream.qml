pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia

// The QtMultimedia import is quarantined here on purpose. A QML document whose
// import cannot be resolved fails to load in its entirety, so importing it in
// the viewport would cost the whole panel on a machine without qt6-multimedia
// rather than just the live stream. Nothing loads this file directly: the
// viewport reaches it through a Loader, and BambuService probes it with
// Qt.createComponent to decide whether to offer the setting at all.
Item {
  id: stream

  property url streamUrl: ""

  // Visibility is owned by the Loader, so playback follows it rather than
  // being driven separately and drifting out of step with the panel.
  readonly property bool playing: stream.visible && String(stream.streamUrl) !== ""

  onPlayingChanged: stream.playing ? player.play() : player.stop()

  MediaPlayer {
    id: player
    videoOutput: sink
    source: stream.playing ? stream.streamUrl : ""
    // The daemon rebuilds its gateway on a fresh port each session, so the URL
    // can change under a player that is already running.
    onSourceChanged: if (stream.playing && String(source) !== "") player.play()
  }

  VideoOutput {
    id: sink
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectFit
  }
}
