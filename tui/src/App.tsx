import { useState } from "react"
import { SessionListScreen } from "./screens/SessionListScreen"
import { RunDashboardScreen } from "./screens/RunDashboardScreen"
import { SummaryScreen } from "./screens/SummaryScreen"

type Screen = "list" | "run" | "summary"

interface AppState {
  screen: Screen
  sessionName?: string
}

export function App() {
  const [state, setState] = useState<AppState>({ screen: "list" })

  const navigateToRun = (sessionName: string) => {
    setState({ screen: "run", sessionName })
  }

  const navigateToSummary = (sessionName: string) => {
    setState({ screen: "summary", sessionName })
  }

  const navigateToList = () => {
    setState({ screen: "list" })
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
