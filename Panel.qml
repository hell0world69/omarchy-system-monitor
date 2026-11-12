import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// System monitor: CPU / RAM / temperature in the bar, with a panel holding a
// CPU history graph, memory and swap meters, load, uptime and the busiest
// processes. Sampling is a bash loop over /proc (sample.sh); the process list
// (top.sh) only runs while the panel is open, to stay light on a small CPU.
//
// All Text pins PlainText: process names come from the system.
Panel {
  id: root
  moduleName: "hell0world.system-monitor"
  ipcTarget: "hell0world.system-monitor"

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------------------------------------------------------------- settings
  readonly property real interval: {
    var v = Number(setting("interval", 2))
    return isFinite(v) ? Math.max(1, Math.min(10, v)) : 2
  }
  readonly property bool showRam: setting("showRam", true) !== false
  readonly property bool showTemp: setting("showTemp", false) === true
  readonly property int cpuWarn: Math.max(1, Math.min(100, Number(setting("cpuWarn", 90)) || 90))
  readonly property int tempWarn: Math.max(30, Math.min(120, Number(setting("tempWarn", 85)) || 85))

  // ------------------------------------------------------------------ state
  property int cpu: 0
  property int ram: 0
  property int swap: 0
  property int temp: -1
  property real load1: 0
  property int uptime: 0
  property real memUsed: 0      // KiB
  property real memTotal: 0     // KiB
  property real swapUsed: 0     // KiB
  property bool sampled: false
  property var history: []     // last 60 CPU samples
  property var processes: []

  readonly property int historyLength: 60
  readonly property bool cpuHot: sampled && cpu >= cpuWarn
  readonly property bool tempHot: temp >= tempWarn
  readonly property bool warning: cpuHot || tempHot

  function clampInt(v, lo, hi) {
    var n = parseInt(v, 10)
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : lo
  }

  function applyLine(line) {
    var f = String(line || "").trim().split(" ")
    if (f.length < 9) return
    cpu = clampInt(f[0], 0, 100)
    ram = clampInt(f[1], 0, 100)
    swap = clampInt(f[2], 0, 100)
    temp = clampInt(f[3], -1, 200)
    load1 = Math.max(0, Number(f[4]) || 0)
    uptime = clampInt(f[5], 0, 1e9)
    memUsed = Math.max(0, Number(f[6]) || 0)
    memTotal = Math.max(0, Number(f[7]) || 0)
    swapUsed = Math.max(0, Number(f[8]) || 0)
    // The first sample has no delta yet, so it is always 0%: skip it.
    if (sampled) {
      var h = history.slice(-(historyLength - 1))
      h.push(cpu)
      history = h
    }
    sampled = true
  }

  function formatKiB(kib) {
    var gib = kib / 1048576
    if (gib >= 1) return strings.t("unit.gib").arg(I18n.formatNumber(gib, gib >= 10 ? 0 : 1))
    return strings.t("unit.mib").arg(I18n.formatNumber(kib / 1024, 0))
  }

  function formatUptime(s) {
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
    if (d > 0) return strings.t("uptime.days").arg(d).arg(h)
    if (h > 0) return strings.t("uptime.hours").arg(h).arg(m)
    return strings.t("uptime.minutes").arg(m)
  }

  // ------------------------------------------------------------- processes
  readonly property string samplePath: String(Qt.resolvedUrl("sample.sh")).replace(/^file:\/\//, "")
  readonly property string topPath: String(Qt.resolvedUrl("top.sh")).replace(/^file:\/\//, "")

  Process {
    id: sampler
    command: ["bash", root.samplePath, String(root.interval)]
    stdout: SplitParser { onRead: function(data) { root.applyLine(data) } }
    onRunningChanged: if (!running) restartTimer.restart()
  }
  onIntervalChanged: { sampler.running = false }
  Component.onCompleted: sampler.running = true
  Timer { id: restartTimer; interval: 2000; onTriggered: sampler.running = true }

  Process {
    id: topProc
    command: ["bash", root.topPath, "6"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = []
        String(text || "").split("\n").slice(0, 6).forEach(function(l) {
          var p = l.split("\t")
          if (p.length < 4) return
          rows.push({
            pid: String(p[0]).substring(0, 10),
            cpu: Math.max(0, Number(p[1]) || 0),
            rss: Math.max(0, Number(p[2]) || 0),
            name: String(p[3]).substring(0, 40)
          })
        })
        root.processes = rows
      }
    }
  }
  // top.sh samples over one second; poll again a beat after it returns.
  Timer {
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: root.opened
    onTriggered: if (!topProc.running) topProc.running = true
  }

  // ----------------------------------------------------------------- bar
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string glyph: String.fromCodePoint(0xF0EE0)   // nf-md-chart_areaspline_variant
  readonly property string barText: {
    if (!sampled) return "…"
    var parts = [strings.t("bar.cpu").arg(cpu)]
    if (showRam) parts.push(strings.t("bar.ram").arg(ram))
    if (showTemp && temp >= 0) parts.push(strings.t("bar.temp").arg(temp))
    return parts.join("  ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: vertical ? 0 : content.implicitWidth

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + Style.bar.iconSlot - Style.bar.iconCanvas)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    active: root.warning
    tooltipText: strings.t("tooltip").arg(root.cpu).arg(root.ram)
      + (root.temp >= 0 ? strings.t("tooltip.temp").arg(root.temp) : "")
    onPressed: function(b) { root.toggle() }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: root.vertical ? 0 : Style.space(4)

      OpticalGlyph {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: root.glyph
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.vertical
        text: root.barText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.features: { "tnum": 1 }
        renderType: Text.NativeRendering
      }
    }
  }

  // ----------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // Hero: big CPU number + load / uptime, btop button on the right
        Item {
          width: parent.width
          implicitHeight: Math.max(heroNumber.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroNumber
            textFormat: Text.PlainText
            text: strings.t("hero.percent").arg(root.cpu)
            color: root.cpuHot ? root.bar.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
            font.features: { "tnum": 1 }
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroNumber.right
            anchors.leftMargin: Style.space(14)
            anchors.right: btopButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: strings.t("label.cpu").toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
            Text {
              textFormat: Text.PlainText
              text: strings.t("hero.load").arg(I18n.formatNumber(root.load1, 2)).arg(root.formatUptime(root.uptime))
              color: root.bar.foreground
              opacity: 0.7
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PanelActionButton {
            id: btopButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: String.fromCodePoint(0xF018D)   // nf-md-console
            tooltipText: strings.t("action.btop")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: {
              root.close()
              Quickshell.execDetached(["omarchy", "launch", "or", "focus", "tui", "btop"])
            }
          }
        }

        // CPU history graph
        Rectangle {
          id: graphBox
          width: parent.width
          height: Style.space(64)
          radius: Style.space(6)
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.05)
          border.width: 1
          border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          clip: true

          Canvas {
            id: graph
            anchors.fill: parent
            anchors.margins: 1
            readonly property var points: root.history
            readonly property color lineColor: root.cpuHot ? root.bar.urgent : root.bar.foreground
            onPointsChanged: if (root.opened) requestPaint()
            onLineColorChanged: requestPaint()
            onWidthChanged: requestPaint()
            Connections { target: root; function onOpenedChanged() { if (root.opened) graph.requestPaint() } }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var pts = points, n = pts.length
              if (n < 2) return
              var step = width / (root.historyLength - 1)
              var x0 = width - (n - 1) * step
              function y(v) { return height - 2 - (height - 4) * v / 100 }

              ctx.beginPath()
              ctx.moveTo(x0, height)
              for (var i = 0; i < n; i++) ctx.lineTo(x0 + i * step, y(pts[i]))
              ctx.lineTo(width, height)
              ctx.closePath()
              ctx.fillStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.15)
              ctx.fill()

              ctx.beginPath()
              for (var j = 0; j < n; j++) {
                if (j === 0) ctx.moveTo(x0, y(pts[0]))
                else ctx.lineTo(x0 + j * step, y(pts[j]))
              }
              ctx.strokeStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.85)
              ctx.lineWidth = 1.5
              ctx.stroke()
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(6)
            text: strings.t("graph.window").arg(Math.round(root.historyLength * root.interval / 60))
            color: root.bar.foreground
            opacity: 0.45
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Meters
        Column {
          width: parent.width
          spacing: Style.space(8)

          Meter {
            label: strings.t("label.memory")
            percent: root.ram
            detail: strings.t("value.of").arg(root.formatKiB(root.memUsed)).arg(root.formatKiB(root.memTotal))
          }
          Meter {
            label: strings.t("label.swap")
            percent: root.swap
            detail: root.formatKiB(root.swapUsed)
          }
          Meter {
            visible: root.temp >= 0
            label: strings.t("label.temp")
            percent: Math.min(100, root.temp)
            hot: root.tempHot
            showPercent: false
            detail: strings.t("value.temp").arg(root.temp)
          }
        }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground }

        PanelSectionHeader {
          text: strings.t("label.processes")
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            visible: root.processes.length === 0
            textFormat: Text.PlainText
            text: strings.t("processes.loading")
            color: root.bar.foreground
            opacity: 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.processes
            delegate: Item {
              required property var modelData
              width: parent.width
              implicitHeight: procName.implicitHeight

              Text {
                id: procName
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: procMem.left
                anchors.rightMargin: Style.space(8)
                text: modelData.name
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                id: procMem
                textFormat: Text.PlainText
                anchors.right: procCpu.left
                anchors.rightMargin: Style.space(10)
                width: Style.space(64)
                horizontalAlignment: Text.AlignRight
                text: root.formatKiB(modelData.rss)
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.features: { "tnum": 1 }
              }
              Text {
                id: procCpu
                textFormat: Text.PlainText
                anchors.right: parent.right
                width: Style.space(52)
                horizontalAlignment: Text.AlignRight
                text: strings.t("value.percent").arg(I18n.formatNumber(modelData.cpu, 1))
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.features: { "tnum": 1 }
              }
            }
          }
        }
      }
    }
  }

  component Meter: Column {
    property string label: ""
    property string detail: ""
    property int percent: 0
    property bool hot: percent >= 90
    property bool showPercent: true
    readonly property color tint: hot ? root.bar.urgent : root.bar.foreground

    width: parent.width
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: meterLabel.implicitHeight

      Text {
        id: meterLabel
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: label
        color: root.bar.foreground
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: showPercent ? strings.t("value.meter").arg(detail).arg(percent) : detail
        color: tint
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.features: { "tnum": 1 }
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(6)
      radius: height / 2
      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.1)

      Rectangle {
        width: parent.width * Math.max(0, Math.min(100, percent)) / 100
        height: parent.height
        radius: parent.radius
        color: tint
        opacity: 0.8
        Behavior on width { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
      }
    }
  }
}
