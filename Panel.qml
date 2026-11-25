import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Monitor Arrangement: a bar widget whose panel shows the enabled screens to
// scale and moves one next to another with Left / Above / Below / Right.
//
//   click a screen    choose which screen the buttons move
//   buttons           place it next to the other screen and save the layout
//   j / k             cycle which screen is chosen
//   h / l, Enter      pick a direction and apply it
//
// The work is done by arrange.py, which writes ~/.config/hypr/monitors.lua and
// reloads Hyprland (restoring the old file if Hyprland reports errors).
Panel {
  id: root
  moduleName: "kunush.monitor-arrangement"
  ipcTarget: "kunush.monitor-arrangement"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("arrange.py")).replace(/^file:\/\//, ""))
  readonly property var directions: ["left", "above", "below", "right"]
  readonly property var glyphs: ({ left: "←", above: "↑", below: "↓", right: "→" })

  property var layout: []
  property string selectedName: ""
  property bool failed: false
  property int cursorIndex: 0
  property bool cursorActive: false

  // The screen the buttons move: the one clicked, else the first external.
  readonly property var target: {
    var list = layout
    for (var i = 0; i < list.length; i++)
      if (list[i].name === selectedName) return list[i]
    for (var j = 0; j < list.length; j++)
      if (!list[j].internal) return list[j]
    return list.length ? list[0] : null
  }
  // What it moves around: the laptop screen when there is one.
  readonly property var anchor: {
    var list = layout
    var t = target
    if (!t) return null
    var others = []
    for (var i = 0; i < list.length; i++)
      if (list[i].name !== t.name) others.push(list[i])
    for (var j = 0; j < others.length; j++)
      if (others[j].internal) return others[j]
    return others.length ? others[0] : null
  }
  // Where the target sits relative to the anchor now, judged by centres.
  readonly property string current: {
    var t = target, a = anchor
    if (!t || !a) return ""
    var dx = (t.x + t.w / 2) - (a.x + a.w / 2)
    var dy = (t.y + t.h / 2) - (a.y + a.h / 2)
    if (Math.abs(dx) >= Math.abs(dy)) return dx < 0 ? "left" : "right"
    return dy < 0 ? "above" : "below"
  }

  function label(m) {
    if (!m) return ""
    return m.internal ? strings.t("arrange.laptop") : m.name
  }

  function refresh() {
    if (!layoutProc.running && !placeProc.running) layoutProc.running = true
  }

  function updateLayout(text) {
    var parsed = []
    try { parsed = JSON.parse(String(text || "[]")) } catch (e) { parsed = [] }
    if (!Array.isArray(parsed)) parsed = []
    var clean = []
    for (var i = 0; i < parsed.length && clean.length < 8; i++) {
      var m = parsed[i]
      if (!m || typeof m.name !== "string") continue
      clean.push({
        name: m.name.slice(0, 64),
        x: Number(m.x) || 0, y: Number(m.y) || 0,
        w: Math.max(1, Number(m.w) || 1), h: Math.max(1, Number(m.h) || 1),
        internal: m.internal === true
      })
    }
    root.layout = clean
  }

  function place(direction) {
    var t = root.target, a = root.anchor
    if (!t || !a || placeProc.running) return
    if (root.directions.indexOf(direction) < 0) return
    root.failed = false
    placeProc.command = ["python3", "-I", root.script, "place", t.name, direction, a.name]
    placeProc.running = true
  }

  function cycleTarget(delta) {
    var list = root.layout
    if (list.length < 2) return
    var idx = 0
    for (var i = 0; i < list.length; i++)
      if (root.target && list[i].name === root.target.name) idx = i
    idx = (idx + delta + list.length) % list.length
    root.selectedName = list[idx].name
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) {
    refresh()
    root.cursorActive = false
    root.cursorIndex = Math.max(0, root.directions.indexOf(root.current))
  }

  // Monitors come and go (docks, lids), so re-read while the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: layoutProc
    command: ["python3", "-I", root.script, "layout"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateLayout(text)
    }
  }

  Process {
    id: placeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.updateLayout(text)
    }
    onExited: function(exitCode) {
      root.failed = exitCode !== 0
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍺"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(420))

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.cycleTarget(dy)
        else if (dx !== 0) root.cursorIndex = Math.max(0, Math.min(root.directions.length - 1, root.cursorIndex + dx))
      }
      onActivateRequested: if (root.cursorActive) root.place(root.directions[root.cursorIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰍺"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: strings.t("arrange.panelTitle")
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: strings.tn("arrange.screens", root.layout.length)
                      .arg(Commons.I18n.formatNumber(root.layout.length)).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Only one screen ----------
        Text {
          visible: root.layout.length < 2
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("arrange.single")
          wrapMode: Text.WordWrap
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---------- Arrangement ----------
        Column {
          visible: root.layout.length > 1
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(header.implicitHeight, caption.implicitHeight)

            PanelSectionHeader {
              id: header
              text: strings.t("arrange.title")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: caption
              textFormat: Text.PlainText
              text: root.failed
                ? strings.t("arrange.failed")
                : strings.t("arrange.relative").arg(root.label(root.target)).arg(root.label(root.anchor))
              color: root.failed ? Commons.Color.urgent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignRight
              width: parent.width - header.implicitWidth - Style.space(18)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Screens drawn to scale; click one to choose it.
          Item {
            id: map
            width: parent.width
            height: Style.space(130)

            readonly property var bounds: {
              var list = root.layout
              if (!list.length) return { x: 0, y: 0, w: 1, h: 1 }
              var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9
              for (var i = 0; i < list.length; i++) {
                minX = Math.min(minX, list[i].x); minY = Math.min(minY, list[i].y)
                maxX = Math.max(maxX, list[i].x + list[i].w); maxY = Math.max(maxY, list[i].y + list[i].h)
              }
              return { x: minX, y: minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) }
            }
            readonly property real factor: Math.min((width - Style.space(12)) / bounds.w, (height - Style.space(8)) / bounds.h)
            readonly property real offsetX: (width - bounds.w * factor) / 2
            readonly property real offsetY: (height - bounds.h * factor) / 2

            Repeater {
              model: root.layout

              Rectangle {
                id: screen
                required property var modelData
                readonly property bool picked: root.target !== null && root.target.name === modelData.name
                readonly property real gap: Style.space(2)

                x: map.offsetX + (modelData.x - map.bounds.x) * map.factor + gap
                y: map.offsetY + (modelData.y - map.bounds.y) * map.factor + gap
                width: Math.max(4, modelData.w * map.factor - gap * 2)
                height: Math.max(4, modelData.h * map.factor - gap * 2)
                radius: Style.space(4)
                color: picked
                  ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                  : (screenMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent")
                border.width: picked ? 2 : 1
                border.color: picked ? Commons.Color.accent : Qt.darker(root.bar.foreground, 1.6)

                Behavior on x { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
                Behavior on y { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }

                Column {
                  anchors.centerIn: parent
                  width: parent.width - Style.space(8)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: screen.modelData.internal ? "󰌢" : "󰍹"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.subtitle
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.label(screen.modelData)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: screen.picked
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                  }
                }

                MouseArea {
                  id: screenMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedName = screen.modelData.name
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.layout.length > 2 || root.selectedName === ""
            textFormat: Text.PlainText
            text: strings.t("arrange.hint")
            horizontalAlignment: Text.AlignHCenter
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Grid {
            id: buttons
            width: parent.width
            columns: root.directions.length
            spacing: Style.spacing.xs
            enabled: !placeProc.running

            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: root.directions

              Button {
                id: pill
                required property string modelData
                required property int index

                width: buttons.cellWidth
                text: root.glyphs[modelData] + " " + strings.t("arrange." + modelData)
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                active: root.current === modelData
                hasCursor: root.cursorActive && root.cursorIndex === index

                onClicked: root.place(modelData)
                onHovered: function(isHovered) {
                  if (!isHovered) return
                  root.cursorActive = true
                  root.cursorIndex = pill.index
                }
              }
            }
          }
        }

        Item { width: parent.width; height: Style.space(4) }
      }
    }
  }
}
