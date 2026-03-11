import { useState } from "react"
import { SessionListScreen } from "./screens/SessionListScreen"

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

  // Phase 2: RunDashboardScreen — show list until implemented
  // navigateToList is used as back-navigation callback in Phase 2
  void navigateToList
  return (
    <SessionListScreen onNavigate={navigateToRun} />
  )
}
