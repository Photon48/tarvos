import { useRenderer } from "@opentui/react"
import { useKeyboard } from "@opentui/react"

export function App() {
  const renderer = useRenderer()

  useKeyboard((key) => {
    if (key.name === "q" || (key.ctrl && key.name === "c")) {
      renderer.destroy()
    }
  })

  return (
    <box
      flexDirection="column"
      width="100%"
      height="100%"
      backgroundColor="#1C1C1C"
    >
      <box
        flexDirection="row"
        width="100%"
        backgroundColor="#5F00AF"
        padding={1}
      >
        <text fg="#D75FAF">
          <strong>TARVOS</strong>
        </text>
        <text fg="#D0D0D0"> — Session Manager</text>
      </box>
      <box
        flexGrow={1}
        flexDirection="column"
        justifyContent="center"
        alignItems="center"
      >
        <text fg="#D0D0D0">Loading sessions...</text>
      </box>
      <box
        flexDirection="row"
        width="100%"
        backgroundColor="#303030"
        padding={1}
      >
        <text fg="#585858">[q] Quit</text>
      </box>
    </box>
  )
}
