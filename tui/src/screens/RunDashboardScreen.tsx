import { useState, useEffect, useCallback, useReducer, useRef } from "react"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/react"
import { theme, BRAILLE_SPINNER, statusColors, statusIcons } from "../theme"
import { watchEventsFile } from "../data/events"
import { loadSessions, getSessionDir } from "../data/sessions"
import { runTarvosCommand } from "../commands"
import type { Session, TuiEvent } from "../types"
import { watch } from "fs"
import { join } from "path"

// ─── Types ─────────────────────────────────────────────────────────────────────

type RunStatus =
  | "IDLE"
  | "RUNNING"
  | "CONTEXT_LIMIT"
  | "CONTINUATION"
  | "RECOVERY"
  | "DONE"
  | "ERROR"

interface HistoryEntry {
  loop: number
  signal: string
  tokens: number
  duration: string
}

interface LogEntry {
  id: number
  type: string
  content: string
  raw?: string
}

interface RunState {
  status: RunStatus
  currentLoop: number
  maxLoops: number
  currentPhase: string
  currentSignal: string
  tokenCount: number
  tokenLimit: number
  history: HistoryEntry[]
  activityLog: LogEntry[]
  scrollOffset: number  // 0 = bottom, positive = scrolled up
  viewMode: "summary" | "raw"
}

type RunAction =
  | { type: "SESSION_LOADED"; session: Session }
  | { type: "EVENT"; event: TuiEvent }
  | { type: "SCROLL_UP" }
  | { type: "SCROLL_DOWN" }
  | { type: "TOGGLE_VIEW" }
  | { type: "RESET_SCROLL" }

// ─── Reducer ───────────────────────────────────────────────────────────────────

let nextLogId = 0

function formatEvent(event: TuiEvent, viewMode: "summary" | "raw"): string {
  if (viewMode === "raw" && event.raw) return event.raw

  switch (event.type) {
    case "tool_use":
      return `  Tool: ${event.tool ?? "unknown"}`
    case "text":
      return `  ${(event.content ?? "").slice(0, 120)}`
    case "signal":
      return `  Signal: ${event.signal ?? event.content ?? ""}`
    case "status":
      return `  Status → ${event.content ?? ""}`
    case "tokens":
      return `  Tokens: ${event.tokens ?? 0}`
    case "phase":
      return `  Phase: ${event.phase ?? event.content ?? ""}`
    default:
      return `  [${event.type}] ${event.content ?? ""}`
  }
}

function reducer(state: RunState, action: RunAction): RunState {
  switch (action.type) {
    case "SESSION_LOADED": {
      const s = action.session
      const rawStatus = s.status.toUpperCase() as RunStatus
      return {
        ...state,
        status: rawStatus,
        currentLoop: s.loop_count,
        maxLoops: s.max_loops,
        tokenLimit: s.token_limit,
        currentSignal: s.final_signal ?? "",
      }
    }
    case "EVENT": {
      const ev = action.event
      const logLine: LogEntry = {
        id: nextLogId++,
        type: ev.type,
        content: formatEvent(ev, state.viewMode),
        raw: ev.raw,
      }
      const newLog = [...state.activityLog, logLine].slice(-500)

      let newState = { ...state, activityLog: newLog }

      // Update derived state from event type
      if (ev.type === "tokens" && ev.tokens !== undefined) {
        newState.tokenCount = ev.tokens
      }
      if (ev.type === "phase" && (ev.phase ?? ev.content)) {
        newState.currentPhase = ev.phase ?? ev.content ?? state.currentPhase
      }
      if (ev.type === "signal" && ev.signal) {
        newState.currentSignal = ev.signal
        // Push to history when loop completes
        if (ev.signal === "PHASE_COMPLETE" || ev.signal === "PHASE_IN_PROGRESS" || ev.signal === "ALL_PHASES_COMPLETE") {
          const entry: HistoryEntry = {
            loop: state.currentLoop,
            signal: ev.signal,
            tokens: state.tokenCount,
            duration: "—",
          }
          newState.history = [...state.history, entry]
        }
      }
      if (ev.type === "status") {
        const rawStatus = (ev.content ?? "").toUpperCase()
        if (["IDLE","RUNNING","CONTEXT_LIMIT","CONTINUATION","RECOVERY","DONE","ERROR"].includes(rawStatus)) {
          newState.status = rawStatus as RunStatus
        }
      }

      return newState
    }
    case "SCROLL_UP":
      return { ...state, scrollOffset: state.scrollOffset + 5 }
    case "SCROLL_DOWN":
      return { ...state, scrollOffset: Math.max(0, state.scrollOffset - 5) }
    case "RESET_SCROLL":
      return { ...state, scrollOffset: 0 }
    case "TOGGLE_VIEW":
      return { ...state, viewMode: state.viewMode === "summary" ? "raw" : "summary" }
    default:
      return state
  }
}

// ─── Sub-components ─────────────────────────────────────────────────────────────

function useSpinner(): string {
  const [frame, setFrame] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setFrame(f => (f + 1) % BRAILLE_SPINNER.length), 100)
    return () => clearInterval(id)
  }, [])
  return BRAILLE_SPINNER[frame]
}

// ─── Run Header ───────────────────────────────────────────────────────────────

interface RunHeaderProps {
  sessionName: string
  state: RunState
}

function RunHeader({ sessionName, state }: RunHeaderProps) {
  const spinner = useSpinner()
  const isRunning = state.status === "RUNNING"
  const statusColor = statusColors[state.status.toLowerCase()] ?? theme.normal
  const statusIcon = statusIcons[state.status.toLowerCase()] ?? "?"

  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.headerBg}
      paddingX={2}
      height={1}
    >
      <text fg={theme.accent}>
        <strong>TARVOS</strong>
      </text>
      <text fg={theme.muted}> › </text>
      <text fg={theme.normal}>{sessionName}</text>
      <text fg={theme.muted}> › </text>
      <text fg={statusColor}>{isRunning ? spinner : statusIcon} {state.status}</text>
      <box flexGrow={1} />
      <text fg={theme.muted}>Loop {state.currentLoop}/{state.maxLoops}</text>
    </box>
  )
}

// ─── Context Progress Bar ─────────────────────────────────────────────────────

interface ContextBarProps {
  tokenCount: number
  tokenLimit: number
}

function ContextBar({ tokenCount, tokenLimit }: ContextBarProps) {
  const { width } = useTerminalDimensions()
  const labelLeft = "Context: "
  const labelRight = ` ${tokenCount.toLocaleString()} / ${tokenLimit.toLocaleString()}`
  const barWidth = Math.max(10, width - labelLeft.length - labelRight.length - 4)

  const ratio = tokenLimit > 0 ? Math.min(1, tokenCount / tokenLimit) : 0
  const filled = Math.round(ratio * barWidth)
  const empty = barWidth - filled

  let barColor = theme.success
  if (ratio > 0.9) barColor = theme.error
  else if (ratio > 0.7) barColor = theme.warning

  const bar = "█".repeat(filled) + "░".repeat(empty)

  return (
    <box flexDirection="row" width="100%" paddingX={2} height={1}>
      <text fg={theme.muted}>{labelLeft}</text>
      <text fg={barColor}>{bar}</text>
      <text fg={theme.muted}>{labelRight}</text>
    </box>
  )
}

// ─── Status Panel ─────────────────────────────────────────────────────────────

interface StatusPanelProps {
  state: RunState
  elapsed: string
}

function StatusPanel({ state, elapsed }: StatusPanelProps) {
  const spinner = useSpinner()
  const isRunning = state.status === "RUNNING"
  const statusColor = statusColors[state.status.toLowerCase()] ?? theme.normal

  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.panelBg}
      paddingX={2}
      height={1}
    >
      <text fg={theme.muted}>Status: </text>
      <text fg={statusColor}>{isRunning ? `${spinner} ` : ""}{state.status}</text>
      {state.currentPhase ? (
        <>
          <text fg={theme.muted}>  Phase: </text>
          <text fg={theme.info}>{state.currentPhase}</text>
        </>
      ) : null}
      {state.currentSignal ? (
        <>
          <text fg={theme.muted}>  Signal: </text>
          <text fg={theme.warning}>{state.currentSignal}</text>
        </>
      ) : null}
      <box flexGrow={1} />
      <text fg={theme.subtle}>{elapsed}</text>
    </box>
  )
}

// ─── History Table ─────────────────────────────────────────────────────────────

interface HistoryTableProps {
  history: HistoryEntry[]
}

function HistoryTable({ history }: HistoryTableProps) {
  if (history.length === 0) {
    return (
      <box
        flexDirection="row"
        width="100%"
        backgroundColor={theme.panelBg}
        paddingX={2}
        height={1}
      >
        <text fg={theme.muted}>History: no completed loops yet</text>
      </box>
    )
  }

  // Show only last 3 entries in a single row to save vertical space
  const recent = history.slice(-3)
  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.panelBg}
      paddingX={2}
      height={1}
    >
      <text fg={theme.muted}>History: </text>
      {recent.map((h, i) => (
        <text key={i} fg={theme.subtle}>
          {i > 0 ? "  " : ""}L{h.loop}:{h.signal.replace("PHASE_", "").slice(0,4)} ({h.tokens.toLocaleString()}tk)
        </text>
      ))}
    </box>
  )
}

// ─── Activity Log ─────────────────────────────────────────────────────────────

interface ActivityLogProps {
  entries: LogEntry[]
  scrollOffset: number
  viewMode: "summary" | "raw"
  height: number
}

function ActivityLog({ entries, scrollOffset, viewMode, height }: ActivityLogProps) {
  // Calculate visible window: scrollOffset=0 means bottom
  const total = entries.length
  const visible = Math.max(1, height)
  const startIdx = Math.max(0, total - visible - scrollOffset)
  const endIdx = Math.max(0, total - scrollOffset)
  const visible_entries = entries.slice(startIdx, endIdx)

  const typeColors: Record<string, string> = {
    tool_use: theme.info,
    text:     theme.normal,
    signal:   theme.accent,
    status:   theme.warning,
    tokens:   theme.muted,
    phase:    theme.purple,
  }

  return (
    <box
      flexDirection="column"
      flexGrow={1}
      width="100%"
      backgroundColor="#1C1C1C"
    >
      {/* Column header */}
      <box
        flexDirection="row"
        width="100%"
        backgroundColor={theme.panelBg}
        paddingX={2}
        height={1}
      >
        <text fg={theme.muted}>
          Activity Log{viewMode === "raw" ? " [raw]" : ""} — {total} events{scrollOffset > 0 ? ` (↑ scrolled ${scrollOffset})` : ""}
        </text>
      </box>
      {/* Log entries */}
      {visible_entries.length === 0 ? (
        <box flexGrow={1} justifyContent="center" alignItems="center">
          <text fg={theme.muted}>Waiting for events...</text>
        </box>
      ) : (
        <box flexDirection="column" flexGrow={1} width="100%">
          {visible_entries.map((entry) => {
            const color = typeColors[entry.type] ?? theme.subtle
            return (
              <box key={entry.id} flexDirection="row" width="100%" paddingX={1} height={1}>
                <text fg={color}>{entry.content}</text>
              </box>
            )
          })}
        </box>
      )}
    </box>
  )
}

// ─── Footer ───────────────────────────────────────────────────────────────────

interface RunFooterProps {
  viewMode: "summary" | "raw"
  statusMessage: string
}

function RunFooter({ viewMode, statusMessage }: RunFooterProps) {
  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.panelBg}
      paddingX={2}
      height={1}
    >
      {statusMessage ? (
        <text fg={theme.warning}>{statusMessage}</text>
      ) : (
        <text fg={theme.muted}>
          [↑/k] Scroll up  [↓/j] Scroll down  [v] {viewMode === "summary" ? "Raw" : "Summary"} view  [b] Background  [q] Back
        </text>
      )}
    </box>
  )
}

// ─── RunDashboardScreen ───────────────────────────────────────────────────────

interface RunDashboardScreenProps {
  sessionName: string
  onBack: () => void
}

export function RunDashboardScreen({ sessionName, onBack }: RunDashboardScreenProps) {
  const renderer = useRenderer()
  const { height } = useTerminalDimensions()
  const [statusMessage, setStatusMessage] = useState("")
  const [elapsed, setElapsed] = useState("0s")
  const startTimeRef = useRef(Date.now())

  const [runState, dispatch] = useReducer(reducer, {
    status: "IDLE",
    currentLoop: 0,
    maxLoops: 0,
    currentPhase: "",
    currentSignal: "",
    tokenCount: 0,
    tokenLimit: 200000,
    history: [],
    activityLog: [],
    scrollOffset: 0,
    viewMode: "summary",
  })

  const sessionDir = getSessionDir(sessionName)

  // Load initial session state
  const refreshSession = useCallback(async () => {
    try {
      const sessions = await loadSessions()
      const session = sessions.find(s => s.name === sessionName)
      if (session) {
        dispatch({ type: "SESSION_LOADED", session })
      }
    } catch {}
  }, [sessionName])

  useEffect(() => {
    refreshSession()
  }, [refreshSession])

  // Watch state.json for session status changes
  useEffect(() => {
    const stateFile = join(sessionDir, "state.json")
    let watcher: ReturnType<typeof watch> | null = null
    try {
      watcher = watch(stateFile, { persistent: false }, () => {
        refreshSession()
      })
    } catch {}
    return () => {
      try { watcher?.close() } catch {}
    }
  }, [sessionDir, refreshSession])

  // Watch events file for the current loop
  useEffect(() => {
    const loopNum = runState.currentLoop > 0 ? runState.currentLoop : 1
    const cleanup = watchEventsFile(sessionDir, loopNum, (event) => {
      dispatch({ type: "EVENT", event })
    })
    return cleanup
  }, [sessionDir, runState.currentLoop])

  // Elapsed time counter
  useEffect(() => {
    startTimeRef.current = Date.now()
    const id = setInterval(() => {
      const secs = Math.floor((Date.now() - startTimeRef.current) / 1000)
      if (secs < 60) setElapsed(`${secs}s`)
      else if (secs < 3600) setElapsed(`${Math.floor(secs / 60)}m ${secs % 60}s`)
      else setElapsed(`${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m`)
    }, 1000)
    return () => clearInterval(id)
  }, [])

  // Clear status message
  useEffect(() => {
    if (!statusMessage) return
    const id = setTimeout(() => setStatusMessage(""), 4000)
    return () => clearTimeout(id)
  }, [statusMessage])

  // Keyboard handler
  useKeyboard((key) => {
    if (key.name === "q" || key.name === "escape") {
      onBack()
      return
    }
    if (key.ctrl && key.name === "c") {
      renderer.destroy()
      return
    }
    if (key.name === "up" || key.name === "k") {
      dispatch({ type: "SCROLL_UP" })
      return
    }
    if (key.name === "down" || key.name === "j") {
      dispatch({ type: "SCROLL_DOWN" })
      return
    }
    if (key.name === "v") {
      dispatch({ type: "TOGGLE_VIEW" })
      return
    }
    if (key.name === "G") {
      dispatch({ type: "RESET_SCROLL" })
      return
    }
    if (key.name === "b") {
      setStatusMessage("Backgrounding session...")
      runTarvosCommand(["background", sessionName]).then(({ exitCode }) => {
        setStatusMessage(exitCode === 0 ? "✓ Session backgrounded" : "✗ Background failed")
      })
      return
    }
    if (key.name === "r") {
      refreshSession()
      setStatusMessage("Refreshed")
      return
    }
  })

  // Reserve rows: header(1) + context_bar(1) + status_panel(1) + history(1) + footer(1) + log_header(1) = 6
  const logHeight = Math.max(4, height - 6)

  return (
    <box flexDirection="column" width="100%" height="100%" backgroundColor="#1C1C1C">
      <RunHeader sessionName={sessionName} state={runState} />
      <StatusPanel state={runState} elapsed={elapsed} />
      <ContextBar tokenCount={runState.tokenCount} tokenLimit={runState.tokenLimit} />
      <HistoryTable history={runState.history} />
      <ActivityLog
        entries={runState.activityLog}
        scrollOffset={runState.scrollOffset}
        viewMode={runState.viewMode}
        height={logHeight}
      />
      <RunFooter viewMode={runState.viewMode} statusMessage={statusMessage} />
    </box>
  )
}
