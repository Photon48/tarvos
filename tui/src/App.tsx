import { useState } from "react"
import { useTerminalDimensions } from "@opentui/react"
import { SessionListScreen } from "./screens/SessionListScreen"
import { RunDashboardScreen } from "./screens/RunDashboardScreen"
import { SummaryScreen } from "./screens/SummaryScreen"

type Screen = "list" | "run" | "summary"

interface AppState {
  screen: Screen
  sessionName?: string
}

// Determine initial screen from env var (for `tarvos tui view <session>`)
function getInitialState(): AppState {
  const initialSession = process.env.TARVOS_TUI_INITIAL_SESSION
  if (initialSession) {
    return { screen: "run", sessionName: initialSession }
  }
  return { screen: "list" }
}

// ─── Narrow terminal warning ──────────────────────────────────────────────────

function NarrowWarning({ width }: { width: number }) {
  return (
    <box
      width="100%"
      height="100%"
      flexDirection="column"
      alignItems="center"
      justifyContent="center"
    >
      <text fg="#FFAF00"><strong>Terminal too narrow.</strong></text>
      <text fg="#AAAAAA">Please resize to at least 80 columns.</text>
      <text fg="#666666">{`Current: ${width} columns`}</text>
    </box>
  )
}

export function App() {
  const { width } = useTerminalDimensions()
  const [state, setState] = useState<AppState>(getInitialState)

  const navigateToRun = (sessionName: string) => {
    setState({ screen: "run", sessionName })
  }

  const navigateToSummary = (sessionName: string) => {
    setState({ screen: "summary", sessionName })
  }

  const navigateToList = () => {
    setState({ screen: "list" })
  }

  // 5.1: Show narrow-terminal warning if width < 80
  if (width > 0 && width < 80) {
    return <NarrowWarning width={width} />
  }

  if (state.screen === "list") {
    return (
      <SessionListScreen
        onNavigate={navigateToRun}
        onViewSummary={navigateToSummary}
      />
    )
  }

  if (state.screen === "run" && state.sessionName) {
    return (
      <RunDashboardScreen
        sessionName={state.sessionName}
        onBack={navigateToList}
        onViewSummary={navigateToSummary}
      />
    )
  }

  if (state.screen === "summary" && state.sessionName) {
    return (
      <SummaryScreen
        sessionName={state.sessionName}
        onBack={navigateToList}
      />
    )
  }

  return (
    <SessionListScreen
      onNavigate={navigateToRun}
      onViewSummary={navigateToSummary}
    />
  )
}
