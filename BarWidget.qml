import QtQuick
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "elvisgastelum.omapass"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("elvisgastelum.omapass") : null

  implicitWidth: glyph.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Text {
    id: glyph
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: "󰌋"
    color: root.bar ? root.bar.barForeground : "white"
    font.family: root.bar ? root.bar.fontFamily : ""
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (root.bar && root.bar.shell) root.bar.shell.toggle("elvisgastelum.omapass", "")
    }
  }
}
