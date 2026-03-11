import { useState } from "react"
import { SessionListScreen } from "./screens/SessionListScreen"
import { RunDashboardScreen } from "./screens/RunDashboardScreen"

type Screen = "list" | "run"

interface AppState {
  screen: Screen
  sessionName?: string
}

export function App() {
  const [state, setState] = useState<AppState>({ screen: "list" })

  const navigateToRun = (sessionName: string) => {
    setState({ screen: "run", sessionName })
  }

  const navigateToList = () => {
    setState({ screen: "list" })
  }

  if (state.screen === "list") {
    return <SessionListScreen onNavigate={navigateToRun} />
  }

  if (state.screen === "run" && state.sessionName) {
    return <RunDashboardScreen sessionName={state.sessionName} onBack={navigateToList} />
  }

  return <SessionListScreen onNavigate={navigateToRun} />
}
