import { useState, useEffect, useCallback, useReducer, useRef } from "react"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/react"
import { theme, BRAILLE_SPINNER, statusColors } from "../theme"
import { watchLogDir } from "../data/events"
import { loadSessions, getSessionDir } from "../data/sessions"
import { runTarvosCommand } from "../commands"
import type { Session, TuiEvent } from "../types"
import { Owl, type OwlState } from "../components/Owl"
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

interface ActionEntry {
  id: number
  icon: string    // "◐" | "✎" | "$" | "⚡" | "◈" | "⊕" | "?"
  type: string    // "Read" | "Edit" | "Bash" | "Signal" | "Phase" | etc.
  arg: string     // truncated argument/content
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
  // New dashboard fields
  currentTool: string
  currentArg: string
  currentText: string
  recentActions: ActionEntry[]
  scrollOffset: number  // 0 = bottom, positive = scrolled up
  viewMode: "summary" | "raw"
}

type RunAction =
  | { type: "SESSION_LOADED"; session: Session }
  | { type: "EVENT"; event: TuiEvent }
  | { type: "LOOP_START"; loop: number }
  | { type: "SCROLL_UP" }
  | { type: "SCROLL_DOWN" }
  | { type: "TOGGLE_VIEW" }
  | { type: "RESET_SCROLL" }

// ─── Tool icon mapping ────────────────────────────────────────────────────────

const TOOL_ICONS: Record<string, string> = {
  Read: "◐", Glob: "◐", Grep: "◐",
  Edit: "✎", Write: "✎", MultiEdit: "✎",
  Bash: "$",
  Task: "⊕",
}

function toolIcon(name: string): string {
  return TOOL_ICONS[name] ?? "·"
}

// ─── Reducer ───────────────────────────────────────────────────────────────────

let nextLogId = 0

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
    case "LOOP_START": {
      return { ...state, currentLoop: action.loop }
    }
    case "EVENT": {
      const ev = action.event
      let newState = { ...state }

      if (ev.type === "tokens" && ev.tokens !== undefined) {
        newState.tokenCount = ev.tokens
      }

      if (ev.type === "text" && ev.content) {
        // Update currentText (last non-empty text snippet), do NOT add to recentActions
        newState.currentText = ev.content
      }

      if (ev.type === "tool_use" && ev.tool) {
        newState.currentTool = ev.tool
        newState.currentArg = ev.arg ?? ""
        const icon = toolIcon(ev.tool)
        const entry: ActionEntry = {
          id: nextLogId++,
          icon,
          type: ev.tool,
          arg: ev.arg ?? "",
        }
        newState.recentActions = [...state.recentActions, entry].slice(-15)
      }

      if (ev.type === "phase" && (ev.phase ?? ev.content)) {
        newState.currentPhase = ev.phase ?? ev.content ?? state.currentPhase
        const entry: ActionEntry = {
          id: nextLogId++,
          icon: "◈",
          type: "Phase",
          arg: newState.currentPhase,
        }
        newState.recentActions = [...state.recentActions, entry].slice(-15)
      }

      if (ev.type === "signal" && ev.signal) {
        newState.currentSignal = ev.signal
        // Push to history when loop completes
        if (ev.signal === "PHASE_COMPLETE" || ev.signal === "PHASE_IN_PROGRESS" || ev.signal === "ALL_PHASES_COMPLETE") {
          const histEntry: HistoryEntry = {
            loop: state.currentLoop,
            signal: ev.signal,
            tokens: state.tokenCount,
            duration: "—",
          }
          newState.history = [...state.history, histEntry]
          // Push to recentActions with ⚡ icon
          const actionEntry: ActionEntry = {
            id: nextLogId++,
            icon: "⚡",
            type: "Signal",
            arg: ev.signal,
          }
          newState.recentActions = [...state.recentActions, actionEntry].slice(-15)
        }
      }

      if (ev.type === "status") {
        const rawStatus = (ev.content ?? "").toUpperCase()
        if (["IDLE","RUNNING","CONTEXT_LIMIT","CONTINUATION","RECOVERY","DONE","ERROR"].includes(rawStatus)) {
          newState.status = rawStatus as RunStatus
        }
      }

      if (ev.type === "loop_start" && ev.loop !== undefined) {
        newState.currentLoop = ev.loop
        newState.status = "RUNNING"
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
  const isStopped = (state.status as string) === "STOPPED" || state.status === "IDLE"
  const isDone = state.status === "DONE"
  const isFailed = state.status === "ERROR"

  const owlState: OwlState = isFailed
    ? "error"
    : isDone
    ? "done"
    : isRunning
    ? "working"
    : "idle"

  const bandBg = isRunning
    ? theme.accent
    : isDone
    ? theme.success
    : isFailed
    ? theme.error
    : isStopped
    ? theme.warning
    : theme.headerBg

  const textFg = (isRunning || isDone || isFailed || isStopped) ? "#1C1C1C" : theme.normal
  const mutedFg = (isRunning || isDone || isFailed || isStopped) ? "#3C3C3C" : theme.muted

  const statusLabel = isRunning
    ? `${spinner} RUNNING — Loop ${state.currentLoop}/${state.maxLoops}`
    : isStopped
    ? `◌ STOPPED — press [c] to continue`
    : isDone
    ? `✓ COMPLETE`
    : isFailed
    ? `✗ FAILED`
    : `${state.status} — Loop ${state.currentLoop}/${state.maxLoops}`

  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={bandBg}
      paddingX={2}
      height={1}
    >
      <Owl state={owlState} />
      <text fg={textFg}> <strong>TARVOS</strong></text>
      <text fg={mutedFg}> › </text>
      <text fg={textFg}>{sessionName}</text>
      <text fg={mutedFg}> › </text>
      <text fg={textFg}>{statusLabel}</text>
    </box>
  )
}

// ─── Status Panel (with inline context bar) ──────────────────────────────────

interface StatusPanelProps {
  state: RunState
  elapsed: string
}

function StatusPanel({ state, elapsed }: StatusPanelProps) {
  const spinner = useSpinner()
  const isRunning = state.status === "RUNNING"
  const statusColor = statusColors[state.status.toLowerCase()] ?? theme.normal

  // Inline mini context bar (~20 chars wide)
  const barWidth = 20
  const ratio = state.tokenLimit > 0 ? Math.min(1, state.tokenCount / state.tokenLimit) : 0
  const filled = Math.round(ratio * barWidth)
  const empty = barWidth - filled
  let barColor = theme.success
  if (ratio > 0.9) barColor = theme.error
  else if (ratio > 0.7) barColor = theme.warning
  const bar = "█".repeat(filled) + "░".repeat(empty)

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
      <text fg={theme.muted}>  [</text>
      <text fg={barColor}>{bar}</text>
      <text fg={theme.muted}>] {state.tokenCount.toLocaleString()}tk</text>
      <box flexGrow={1} />
      <text fg={theme.subtle}>{elapsed}</text>
    </box>
  )
}

// ─── Completion Panel ─────────────────────────────────────────────────────────

interface CompletionPanelProps {
  session: Session | null
}

function CompletionPanel({ session }: CompletionPanelProps) {
  const branch = session?.branch ?? ""
  return (
    <box
      border
      borderStyle="rounded"
      borderColor={theme.success}
      flexDirection="column"
      paddingX={2}
      paddingY={1}
      height={9}
    >
      <text fg={theme.success}><strong>✓ All phases complete!</strong></text>
      <text> </text>
      <text fg={theme.normal}>Branch: <span fg={theme.info}>{branch}</span></text>
      <text fg={theme.muted}>Test it: git checkout {branch}</text>
      <text> </text>
      <text fg={theme.muted}>Try the changes in the branch before accepting.</text>
      <text> </text>
      <box flexDirection="row">
        <text fg={theme.success}>[a] Accept &amp; merge</text>
        <text fg={theme.muted}>    </text>
        <text fg={theme.error}>[r] Reject &amp; discard</text>
      </box>
    </box>
  )
}

// ─── wrapText helper ─────────────────────────────────────────────────────────

/**
 * Wraps `text` to fit within `maxWidth` columns, splitting at word boundaries
 * and falling back to hard-wrap for tokens longer than `maxWidth`.
 * Returns an array of line strings.
 */
function wrapText(text: string, maxWidth: number): string[] {
  if (!text || maxWidth <= 0) return []
  const words = text.split(/\s+/)
  const lines: string[] = []
  let current = ""

  for (const word of words) {
    if (!word) continue
    if (word.length >= maxWidth) {
      // Hard-wrap long token
      if (current) { lines.push(current); current = "" }
      for (let i = 0; i < word.length; i += maxWidth) {
        lines.push(word.slice(i, i + maxWidth))
      }
      continue
    }
    const candidate = current ? `${current} ${word}` : word
    if (candidate.length <= maxWidth) {
      current = candidate
    } else {
      if (current) lines.push(current)
      current = word
    }
  }
  if (current) lines.push(current)
  return lines
}

// ─── Agent Dashboard ──────────────────────────────────────────────────────────

interface AgentDashboardProps {
  state: RunState
  session: Session | null
  height: number
  terminalWidth: number
}

function signalBadge(signal: string): string {
  if (signal === "ALL_PHASES_COMPLETE") return "✓ ALL DONE"
  if (signal === "PHASE_COMPLETE") return "✓ COMPLETE"
  if (signal === "PHASE_IN_PROGRESS") return "⟳ IN PROG"
  return signal.slice(0, 10)
}

function signalBadgeColor(signal: string): string {
  if (signal === "ALL_PHASES_COMPLETE") return theme.accent
  if (signal === "PHASE_COMPLETE") return theme.success
  if (signal === "PHASE_IN_PROGRESS") return theme.warning
  return theme.muted
}

function iconColor(icon: string): string {
  if (icon === "◐") return theme.info
  if (icon === "✎") return theme.success
  if (icon === "$") return theme.warning
  if (icon === "◈") return theme.purple
  if (icon === "⚡") return theme.accent
  if (icon === "⊕") return theme.normal
  return theme.muted
}

function AgentDashboard({ state, session, height, terminalWidth }: AgentDashboardProps) {
  const spinner = useSpinner()
  const isRunning = state.status === "RUNNING"
  const isDone = state.status === "DONE"

  // Spotlight: 9 rows if DONE (CompletionPanel), else 8 rows (1 header + 3 arg + 2 text + 2 border)
  const spotlightHeight = isDone ? 9 : 8
  // Timeline header: 1 row
  const timelineHeaderHeight = 1
  // Timeline rows = remaining height
  const timelineHeight = Math.max(0, height - spotlightHeight - timelineHeaderHeight)

  // Trim recentActions to fit timeline
  const visibleActions = state.recentActions.slice(-timelineHeight)

  // Sidebar scrollbox height
  const sidebarContentHeight = Math.max(4, height - 2)

  return (
    <box flexDirection="row" height={height} width="100%">
      {/* Left panel: spotlight + timeline */}
      <box flexDirection="column" flexGrow={1} backgroundColor="#1C1C1C">
        {/* Spotlight / Completion Panel */}
        {isDone ? (
          <CompletionPanel session={session} />
        ) : (
          <box
            border
            borderStyle="rounded"
            height={spotlightHeight}
            paddingX={1}
            backgroundColor="#1C1C1C"
          >
            {state.currentTool ? (() => {
              const wrapCol = Math.max(10, terminalWidth - 6)
              const argLines = wrapText(state.currentArg, wrapCol)
              const argDisplay = argLines.length > 3
                ? [...argLines.slice(0, 2), argLines[2].slice(0, wrapCol - 1) + "…"]
                : argLines
              const textLines = wrapText(state.currentText, wrapCol)
              const textDisplay = textLines.length > 2
                ? [textLines[0], textLines[1].slice(0, wrapCol - 1) + "…"]
                : textLines
              return (
                <>
                  <text fg={theme.muted}>CURRENTLY:  <span fg={theme.info}>{toolIcon(state.currentTool)} {state.currentTool}</span></text>
                  {argDisplay.map((line, i) => (
                    <text key={i} fg={theme.accent}>{line}</text>
                  ))}
                  {textDisplay.map((line, i) => (
                    <text key={i} fg={theme.muted}>{line}</text>
                  ))}
                </>
              )
            })() : (
              <>
                <text fg={theme.muted}>Waiting for agent to start...</text>
              </>
            )}
          </box>
        )}

        {/* Timeline header */}
        <box height={1} paddingX={1} backgroundColor={theme.panelBg}>
          <text fg={theme.muted}>Recent Actions — {state.recentActions.length}</text>
        </box>

        {/* Timeline rows */}
        <box flexDirection="column" flexGrow={1} width="100%">
          {visibleActions.length === 0 ? (
            <box flexGrow={1} justifyContent="center" alignItems="center">
              <text fg={theme.muted}>No actions yet...</text>
            </box>
          ) : (
            visibleActions.map((action) => {
              const ic = iconColor(action.icon)
              const typeColor = ic
              const maxArgLen = Math.max(10, terminalWidth - 34 - 12)
              return (
                <box key={action.id} flexDirection="row" height={1} paddingX={1}>
                  <text fg={ic}>{action.icon}</text>
                  <text fg={theme.muted}> </text>
                  <text fg={typeColor}>{action.type.padEnd(10)}</text>
                  <text fg={theme.subtle}>{action.arg.slice(0, maxArgLen)}</text>
                </box>
              )
            })
          )}
        </box>
      </box>

      {/* Right panel: Loop sidebar */}
      <box
        flexDirection="column"
        width={30}
        backgroundColor={theme.panelBg}
        border
        borderStyle="single"
        borderColor={theme.muted}
        title="Loops"
        titleAlignment="center"
      >
        {state.history.length === 0 && !isRunning ? (
          <box flexGrow={1} justifyContent="center" alignItems="center">
            <text fg={theme.muted}>No loops yet</text>
          </box>
        ) : (
          <box flexDirection="column" height={sidebarContentHeight} overflow="hidden">
            {state.history.map((h, i) => (
              <box key={i} flexDirection="column" paddingX={1}>
                <box flexDirection="row" height={1}>
                  <text fg={theme.muted}>L{h.loop} </text>
                  <text fg={signalBadgeColor(h.signal)}>{signalBadge(h.signal)}</text>
                </box>
                <box flexDirection="row" height={1}>
                  <text fg={theme.subtle}>  {h.tokens.toLocaleString()}tk · {h.duration}</text>
                </box>
              </box>
            ))}
            {/* Current running loop indicator */}
            {isRunning && (
              <box flexDirection="row" height={1} paddingX={1}>
                <text fg={theme.muted}>L{state.currentLoop} </text>
                <text fg={theme.info}>{spinner} running</text>
              </box>
            )}
          </box>
        )}
      </box>
    </box>
  )
}

// ─── Footer ───────────────────────────────────────────────────────────────────

interface RunFooterProps {
  statusMessage: string
  statusIsError: boolean
  runStatus: RunStatus
}

function RunFooter({ statusMessage, statusIsError, runStatus }: RunFooterProps) {
  const isRunning = runStatus === "RUNNING"
  const isStopped = (runStatus as string) === "STOPPED" || runStatus === "IDLE"
  const isDone = runStatus === "DONE"

  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.panelBg}
      paddingX={2}
      height={1}
    >
      {statusMessage ? (
        <text fg={statusIsError ? theme.error : theme.success}>{statusMessage}</text>
      ) : isDone ? (
        <text fg={theme.muted}>[a] Accept  [r] Reject  [q] Back</text>
      ) : (
        <text fg={theme.muted}>
          [↑↓] Scroll  [v] Toggle raw  {isRunning ? "[s] Stop  " : ""}{isStopped ? "[c] Continue  " : ""}[q] Back
        </text>
      )}
    </box>
  )
}

// ─── RunDashboardScreen ───────────────────────────────────────────────────────

interface RunDashboardScreenProps {
  sessionName: string
  onBack: () => void
  onViewSummary?: (sessionName: string) => void
}

export function RunDashboardScreen({ sessionName, onBack, onViewSummary }: RunDashboardScreenProps) {
  const renderer = useRenderer()
  const { height, width } = useTerminalDimensions()
  const [statusMessage, setStatusMessageRaw] = useState("")
  const [statusIsError, setStatusIsError] = useState(false)
  const [elapsed, setElapsed] = useState("0s")
  const startTimeRef = useRef(Date.now())
  const [rejectPending, setRejectPending] = useState(false)
  const rejectTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const setStatusMessage = (msg: string, isError?: boolean) => {
    setStatusMessageRaw(msg)
    setStatusIsError(isError === true)
  }

  const [runState, dispatch] = useReducer(reducer, {
    status: "IDLE",
    currentLoop: 0,
    maxLoops: 0,
    currentPhase: "",
    currentSignal: "",
    tokenCount: 0,
    tokenLimit: 200000,
    history: [],
    currentTool: "",
    currentArg: "",
    currentText: "",
    recentActions: [],
    scrollOffset: 0,
    viewMode: "summary",
  })

  const sessionDir = getSessionDir(sessionName)
  const [session, setSession] = useState<Session | null>(null)

  // Load initial session state
  const refreshSession = useCallback(async () => {
    try {
      const sessions = await loadSessions()
      const found = sessions.find(s => s.name === sessionName)
      if (found) {
        setSession(found)
        dispatch({ type: "SESSION_LOADED", session: found })
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

  // Watch the entire logDir for events across all loops.
  const logDirWatcherRef = useRef<(() => void) | null>(null)
  const logDirPollRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    // Teardown any previous watcher/poller
    logDirWatcherRef.current?.()
    logDirWatcherRef.current = null
    if (logDirPollRef.current) {
      clearInterval(logDirPollRef.current)
      logDirPollRef.current = null
    }

    const logDir = session?.log_dir ?? ""

    const attachWatcher = (dir: string) => {
      const cleanup = watchLogDir(dir, (event: TuiEvent) => {
        dispatch({ type: "EVENT", event })
      })
      logDirWatcherRef.current = cleanup
    }

    if (logDir) {
      attachWatcher(logDir)
    } else {
      // Poll state.json until log_dir appears (up to 15s, every 500ms)
      let pollCount = 0
      const MAX_POLLS = 30 // 30 × 500ms = 15s
      logDirPollRef.current = setInterval(async () => {
        pollCount++
        if (pollCount > MAX_POLLS) {
          clearInterval(logDirPollRef.current!)
          logDirPollRef.current = null
          return
        }
        try {
          const { loadSessions: ls } = await import("../data/sessions")
          const sessions = await ls()
          const found = sessions.find(s => s.name === sessionName)
          if (found?.log_dir) {
            clearInterval(logDirPollRef.current!)
            logDirPollRef.current = null
            dispatch({ type: "SESSION_LOADED", session: found })
            attachWatcher(found.log_dir)
          }
        } catch {}
      }, 500)
    }

    return () => {
      logDirWatcherRef.current?.()
      logDirWatcherRef.current = null
      if (logDirPollRef.current) {
        clearInterval(logDirPollRef.current)
        logDirPollRef.current = null
      }
    }
  }, [session?.log_dir, sessionName])

  // Elapsed time counter — initialized from session.started_at so it doesn't reset on re-mount
  useEffect(() => {
    if (!session?.started_at) return

    const origin = new Date(session.started_at).getTime()
    startTimeRef.current = origin  // never resets on re-mount

    // If session is done and we have both started_at and last_activity, show static final elapsed
    if (session.status === "done" && session.last_activity) {
      const endTime = new Date(session.last_activity).getTime()
      const totalSecs = Math.floor((endTime - origin) / 1000)
      if (totalSecs >= 3600) {
        setElapsed(`${Math.floor(totalSecs / 3600)}h ${Math.floor((totalSecs % 3600) / 60)}m total`)
      } else if (totalSecs >= 60) {
        setElapsed(`${Math.floor(totalSecs / 60)}m ${totalSecs % 60}s total`)
      } else {
        setElapsed(`${totalSecs}s total`)
      }
      return
    }

    const id = setInterval(() => {
      const secs = Math.floor((Date.now() - startTimeRef.current) / 1000)
      if (secs < 60) setElapsed(`${secs}s`)
      else if (secs < 3600) setElapsed(`${Math.floor(secs / 60)}m ${secs % 60}s`)
      else setElapsed(`${Math.floor(secs / 3600)}h ${Math.floor((secs % 3600) / 60)}m`)
    }, 1000)
    return () => clearInterval(id)
  }, [session?.started_at, session?.status, session?.last_activity])

  // Clear status message after 4s
  useEffect(() => {
    if (!statusMessage) return
    const id = setTimeout(() => setStatusMessageRaw(""), 4000)
    return () => clearTimeout(id)
  }, [statusMessage])

  // Cleanup reject timeout on unmount
  useEffect(() => {
    return () => {
      if (rejectTimeoutRef.current) clearTimeout(rejectTimeoutRef.current)
    }
  }, [])

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
    if (key.name === "s" && runState.status === "RUNNING") {
      setStatusMessage("Stopping session...", false)
      runTarvosCommand(["stop", sessionName]).then(({ exitCode, stderr }) => {
        if (exitCode === 0) {
          setStatusMessage("✓ Session stopped", false)
        } else {
          const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
          setStatusMessage(`✗ Stop failed${detail}`, true)
        }
        refreshSession()
      })
      return
    }
    if (key.name === "c" && (runState.status === "IDLE" || (runState.status as string) === "STOPPED")) {
      setStatusMessage("Resuming session...", false)
      runTarvosCommand(["continue", "--detach", sessionName]).then(({ exitCode, stderr }) => {
        if (exitCode === 0) {
          setStatusMessage("✓ Session resumed", false)
        } else {
          const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
          setStatusMessage(`✗ Continue failed${detail}`, true)
        }
        refreshSession()
      })
      return
    }
    // Accept keybind — only when DONE
    if (key.name === "a" && runState.status === "DONE") {
      setStatusMessage("Accepting session...", false)
      runTarvosCommand(["accept", sessionName]).then(({ exitCode, stderr }) => {
        if (exitCode === 0) {
          setStatusMessage("✓ Accepted and merged", false)
          setTimeout(() => onBack(), 1500)
        } else {
          const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
          setStatusMessage(`✗ Accept failed${detail}`, true)
        }
      })
      return
    }
    // Reject keybind — double-press confirm, only when DONE
    if (key.name === "r" && runState.status === "DONE") {
      if (rejectPending) {
        // Second press: execute reject
        if (rejectTimeoutRef.current) clearTimeout(rejectTimeoutRef.current)
        setRejectPending(false)
        setStatusMessage("Rejecting session...", false)
        runTarvosCommand(["reject", sessionName]).then(({ exitCode, stderr }) => {
          if (exitCode === 0) {
            setStatusMessage("✓ Session rejected", false)
            setTimeout(() => onBack(), 1500)
          } else {
            const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
            setStatusMessage(`✗ Reject failed${detail}`, true)
          }
        })
      } else {
        // First press: arm confirm
        setRejectPending(true)
        setStatusMessage("Press [r] again to confirm rejection", false)
        rejectTimeoutRef.current = setTimeout(() => {
          setRejectPending(false)
          setStatusMessageRaw("")
        }, 3000)
      }
      return
    }
  })

  // Layout budget: header(1) + status(1) + footer(1) = 3 fixed rows
  const dashboardHeight = Math.max(10, height - 3)

  return (
    <box flexDirection="column" width="100%" height="100%" backgroundColor="#1C1C1C">
      <RunHeader sessionName={sessionName} state={runState} />
      <StatusPanel state={runState} elapsed={elapsed} />
      <AgentDashboard
        state={runState}
        session={session}
        height={dashboardHeight}
        terminalWidth={width}
      />
      <RunFooter
        statusMessage={statusMessage}
        statusIsError={statusIsError}
        runStatus={runState.status}
      />
    </box>
  )
}
