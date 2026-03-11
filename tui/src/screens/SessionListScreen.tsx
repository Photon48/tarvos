import { useState, useEffect, useCallback } from "react"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/react"
import { theme, statusIcons, statusColors, BRAILLE_SPINNER } from "../theme"
import { loadSessions, getSessionDir, TARVOS_SESSIONS_DIR } from "../data/sessions"
import { runTarvosCommand } from "../commands"
import type { Session } from "../types"
import { Owl, type OwlState } from "../components/Owl"
import fs from "fs"

// ─── Action definitions per status ────────────────────────────────────────────

const ACTIONS: Record<string, Array<{ label: string; description?: string; cmd: string[] }>> = {
  running:     [{ label: "View",     cmd: ["view"] },                    // client-side navigation only
                { label: "Stop",     cmd: ["stop"] }],                   // tarvos stop <name>
  stopped:     [{ label: "Continue", cmd: ["continue", "--detach"] },    // tarvos continue --detach <name>
                { label: "Reject",   cmd: ["reject", "--force"] }],
  done:        [{ label: "Accept",       cmd: ["accept"] },
                { label: "Reject",       cmd: ["reject", "--force"] },
                { label: "Forget",       cmd: ["forget", "--force"], description: "Remove from Tarvos. Branch stays in your repo." },
                { label: "View Summary", cmd: ["summary"] }],
  initialized: [{ label: "Start",    cmd: ["begin", "--detach"] },       // tarvos begin --detach <name>
                { label: "Reject",   cmd: ["reject", "--force"] }],
  failed:      [{ label: "Reject",   cmd: ["reject", "--force"] },
                { label: "Forget",   cmd: ["forget", "--force"], description: "Remove from Tarvos. Branch stays in your repo." }],
}

// ─── Helper: format relative time ────────────────────────────────────────────

function relativeTime(isoStr: string): string {
  const diff = Date.now() - new Date(isoStr).getTime()
  const secs = Math.floor(diff / 1000)
  if (secs < 60)  return `${secs}s ago`
  const mins = Math.floor(secs / 60)
  if (mins < 60)  return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24)   return `${hrs}h ago`
  return `${Math.floor(hrs / 24)}d ago`
}

// ─── Spinner hook ─────────────────────────────────────────────────────────────

function useSpinner(): string {
  const [frame, setFrame] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setFrame(f => (f + 1) % BRAILLE_SPINNER.length), 100)
    return () => clearInterval(id)
  }, [])
  return BRAILLE_SPINNER[frame]
}

// ─── Header ───────────────────────────────────────────────────────────────────

interface HeaderProps {
  sessions: Session[]
}

function Header({ sessions }: HeaderProps) {
  const [time, setTime] = useState(() => new Date().toLocaleTimeString())
  useEffect(() => {
    const id = setInterval(() => setTime(new Date().toLocaleTimeString()), 1000)
    return () => clearInterval(id)
  }, [])

  // Determine owl state from sessions
  const owlState: OwlState = sessions.some(s => s.status === "failed")
    ? "error"
    : sessions.some(s => s.status === "running")
    ? "working"
    : sessions.some(s => s.status === "done" || s.status === "stopped")
    ? "idle"
    : "idle"

  const runningCount = sessions.filter(s => s.status === "running").length
  const countLabel = `${sessions.length} session${sessions.length !== 1 ? "s" : ""}, ${runningCount} running`

  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.headerBg}
      paddingX={2}
      paddingY={0}
      height={1}
    >
      <Owl state={owlState} />
      <text fg={theme.accent}> <strong>TARVOS</strong></text>
      <text fg={theme.normal}> — Session Manager</text>
      <text fg={theme.muted}>  [{countLabel}]</text>
      <box flexGrow={1} />
      <text fg={theme.muted}>{time}</text>
    </box>
  )
}

// ─── Session Row ──────────────────────────────────────────────────────────────

interface SessionRowProps {
  session: Session
  selected: boolean
  spinnerFrame: string
}

function SessionRow({ session, selected, spinnerFrame }: SessionRowProps) {
  const { width } = useTerminalDimensions()
  const bg = selected ? theme.selBg : undefined
  const icon = statusIcons[session.status] ?? "?"
  const color = statusColors[session.status] ?? theme.normal
  const spinner = session.status === "running" ? spinnerFrame : " "

  // Calculate available space for name (rough estimate)
  const nameWidth = Math.max(10, Math.floor(width * 0.3))
  const branchWidth = Math.max(8, Math.floor(width * 0.2))

  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={bg}
      paddingX={1}
      height={1}
    >
      {/* Spinner */}
      <text fg={theme.accent}>{spinner} </text>
      {/* Status icon */}
      <text fg={color}>{icon} </text>
      {/* Session name */}
      <box width={nameWidth}>
        <text fg={selected ? theme.normal : theme.normal}>
          {session.name.slice(0, nameWidth - 1).padEnd(nameWidth - 1)}
        </text>
      </box>
      <text fg={theme.muted}> </text>
      {/* Branch */}
      <box width={branchWidth}>
        <text fg={theme.subtle}>
          {session.branch.slice(0, branchWidth - 1).padEnd(branchWidth - 1)}
        </text>
      </box>
      <text fg={theme.muted}> </text>
      {/* Loop count */}
      <box width={8}>
        <text fg={theme.muted}>
          {`L:${session.loop_count}`.padEnd(7)}
        </text>
      </box>
      {/* Activity time */}
      <box flexGrow={1} alignItems="flex-end">
        <text fg={theme.subtle}>{relativeTime(session.last_activity)}</text>
      </box>
    </box>
  )
}

// ─── Session Table ─────────────────────────────────────────────────────────────

interface SessionTableProps {
  sessions: Session[]
  selectedIndex: number
}

function SessionTable({ sessions, selectedIndex }: SessionTableProps) {
  const spinner = useSpinner()
  const { width } = useTerminalDimensions()
  const showHeaders = width >= 80

  if (sessions.length === 0) {
    return (
      <box
        flexGrow={1}
        justifyContent="center"
        alignItems="center"
        flexDirection="column"
        gap={1}
      >
        <text fg={theme.muted}>No sessions found.</text>
        <text fg={theme.subtle}>Press [n] to create a new session.</text>
      </box>
    )
  }

  return (
    <box flexDirection="column" flexGrow={1} width="100%">
      {/* Column headers — only show when terminal width >= 80 */}
      {showHeaders ? (
        <box
          flexDirection="row"
          width="100%"
          backgroundColor={theme.panelBg}
          paddingX={1}
          height={1}
        >
          <text fg={theme.muted}>{"  "}</text>
          <text fg={theme.muted}>{"  STATUS"}</text>
          <box flexGrow={1} />
          <text fg={theme.muted}>{"BRANCH        LOOPS  ACTIVITY"}</text>
        </box>
      ) : null}
      {/* Session rows */}
      <box flexDirection="column" flexGrow={1} width="100%">
        {sessions.map((session, i) => (
          <SessionRow
            key={session.name}
            session={session}
            selected={i === selectedIndex}
            spinnerFrame={spinner}
          />
        ))}
      </box>
    </box>
  )
}

// ─── Reject Confirmation Dialog ───────────────────────────────────────────────

interface RejectConfirmProps {
  sessionName: string
  onConfirm: () => void
  onCancel: () => void
}

function RejectConfirmDialog({ sessionName, onConfirm, onCancel }: RejectConfirmProps) {
  useKeyboard((key) => {
    if (key.name === "return") {
      onConfirm()
      return
    }
    if (key.name === "escape") {
      onCancel()
      return
    }
  })

  return (
    <box
      position="absolute"
      top={4}
      left={4}
      width={50}
      flexDirection="column"
      backgroundColor={theme.panelBg}
      border
      borderStyle="rounded"
      borderColor={theme.error}
      title=" Confirm Reject "
      titleAlignment="center"
      padding={1}
      gap={1}
    >
      <text fg={theme.normal}>Reject '{sessionName}'?</text>
      <text fg={theme.warning}>This will delete the branch and all session data.</text>
      <text fg={theme.muted}>  [Enter] Confirm   [Esc] Cancel</text>
    </box>
  )
}

// ─── Forget Confirmation Dialog ──────────────────────────────────────────────

interface ForgetConfirmProps {
  sessionName: string
  branchName: string
  onConfirm: () => void
  onCancel: () => void
}

function ForgetConfirmDialog({ sessionName, branchName, onConfirm, onCancel }: ForgetConfirmProps) {
  useKeyboard((key) => {
    if (key.name === "return") {
      onConfirm()
      return
    }
    if (key.name === "escape") {
      onCancel()
      return
    }
  })

  return (
    <box
      position="absolute"
      top={4}
      left={4}
      width={58}
      flexDirection="column"
      backgroundColor={theme.panelBg}
      border
      borderStyle="rounded"
      borderColor={theme.warning}
      title=" Confirm Forget "
      titleAlignment="center"
      padding={1}
      gap={1}
    >
      <text fg={theme.normal}>Forget '{sessionName}'?</text>
      <text fg={theme.muted}>Tarvos will stop tracking this session.</text>
      <text fg={theme.subtle}>Branch '{branchName}' will remain in your repo.</text>
      <text fg={theme.subtle}>You can check it out, merge it, or delete it manually.</text>
      <text fg={theme.muted}>  [Enter] Confirm   [Esc] Cancel</text>
    </box>
  )
}

// ─── Action Overlay ───────────────────────────────────────────────────────────

interface ActionOverlayProps {
  session: Session
  onClose: () => void
  onNavigate: (sessionName: string) => void
  onViewSummary: (sessionName: string) => void
  setStatusMessage: (msg: string, isError?: boolean) => void
  onRejectSucceeded: () => void
  onAcceptSucceeded: (sessionName: string) => void
  onActionCompleted: () => void
  pendingActions: Set<string>
  onPendingStart: (sessionName: string) => void
  onPendingEnd: (sessionName: string) => void
}

function ActionOverlay({
  session,
  onClose,
  onNavigate,
  onViewSummary,
  setStatusMessage,
  onRejectSucceeded,
  onAcceptSucceeded,
  onActionCompleted,
  pendingActions,
  onPendingStart,
  onPendingEnd,
}: ActionOverlayProps) {
  const [selectedAction, setSelectedAction] = useState(0)
  const [loading, setLoading] = useState(false)
  const [showRejectConfirm, setShowRejectConfirm] = useState(false)
  const [showForgetConfirm, setShowForgetConfirm] = useState(false)
  const actions = ACTIONS[session.status] ?? []
  const isPending = pendingActions.has(session.name)

  const doReject = useCallback(async () => {
    setShowRejectConfirm(false)
    setLoading(true)
    onPendingStart(session.name)
    setStatusMessage(`Running: Reject...`)
    try {
      const { exitCode, stderr } = await runTarvosCommand(["reject", "--force", session.name])
      if (exitCode === 0) {
        setStatusMessage(`✓ Reject succeeded`, false)
        onRejectSucceeded()
        onActionCompleted()
      } else {
        const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
        setStatusMessage(`✗ Reject failed${detail}`, true)
      }
    } catch (e) {
      setStatusMessage(`✗ Error: ${e}`, true)
    } finally {
      setLoading(false)
      onPendingEnd(session.name)
      onClose()
    }
  }, [session, onClose, setStatusMessage, onRejectSucceeded, onActionCompleted, onPendingStart, onPendingEnd])

  const doForget = useCallback(async () => {
    setShowForgetConfirm(false)
    setLoading(true)
    onPendingStart(session.name)
    setStatusMessage(`Running: Forget...`)
    try {
      const { exitCode, stderr } = await runTarvosCommand(["forget", "--force", session.name])
      if (exitCode === 0) {
        setStatusMessage(`✓ Forgotten — branch '${session.branch}' stays in your repo`, false)
        onRejectSucceeded()  // reuse: removes session from list
        onActionCompleted()
      } else {
        const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
        setStatusMessage(`✗ Forget failed${detail}`, true)
      }
    } catch (e) {
      setStatusMessage(`✗ Error: ${e}`, true)
    } finally {
      setLoading(false)
      onPendingEnd(session.name)
      onClose()
    }
  }, [session, onClose, setStatusMessage, onRejectSucceeded, onActionCompleted, onPendingStart, onPendingEnd])

  const executeAction = useCallback(async (action: { label: string; description?: string; cmd: string[] }) => {
    // View navigates client-side
    if (action.cmd[0] === "view") {
      onNavigate(session.name)
      onClose()
      return
    }
    // Summary navigates client-side
    if (action.cmd[0] === "summary") {
      onViewSummary(session.name)
      onClose()
      return
    }
    // Reject requires confirmation dialog
    if (action.cmd[0] === "reject") {
      setShowRejectConfirm(true)
      return
    }
    // Forget requires confirmation dialog
    if (action.cmd[0] === "forget") {
      setShowForgetConfirm(true)
      return
    }

    setLoading(true)
    onPendingStart(session.name)
    setStatusMessage(`Running: ${action.label}...`)
    try {
      const { exitCode, stderr } = await runTarvosCommand([...action.cmd, session.name])
      if (exitCode === 0) {
        setStatusMessage(`✓ ${action.label} succeeded`, false)
        // Optimistic accept removal — remove session from list immediately
        if (action.cmd[0] === "accept") {
          onAcceptSucceeded(session.name)
        }
        onActionCompleted()
      } else {
        const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
        setStatusMessage(`✗ ${action.label} failed${detail}`, true)
      }
    } catch (e) {
      setStatusMessage(`✗ Error: ${e}`, true)
    } finally {
      setLoading(false)
      onPendingEnd(session.name)
      onClose()
    }
  }, [session, onClose, onNavigate, onViewSummary, setStatusMessage, onAcceptSucceeded, onActionCompleted, onPendingStart, onPendingEnd])

  useKeyboard((key) => {
    if (showRejectConfirm || showForgetConfirm) return  // Let confirm dialogs handle keys
    if (loading) return
    if (key.name === "escape") {
      onClose()
      return
    }
    if (key.name === "j" || key.name === "down") {
      setSelectedAction(i => Math.min(i + 1, actions.length - 1))
      return
    }
    if (key.name === "k" || key.name === "up") {
      setSelectedAction(i => Math.max(i - 1, 0))
      return
    }
    if (key.name === "return") {
      const action = actions[selectedAction]
      if (action) executeAction(action)
      return
    }
  })

  if (showRejectConfirm) {
    return (
      <RejectConfirmDialog
        sessionName={session.name}
        onConfirm={doReject}
        onCancel={() => setShowRejectConfirm(false)}
      />
    )
  }

  if (showForgetConfirm) {
    return (
      <ForgetConfirmDialog
        sessionName={session.name}
        branchName={session.branch}
        onConfirm={doForget}
        onCancel={() => setShowForgetConfirm(false)}
      />
    )
  }

  return (
    <box
      position="absolute"
      top={4}
      left={4}
      width={42}
      flexDirection="column"
      backgroundColor={theme.panelBg}
      border
      borderStyle="rounded"
      borderColor={theme.accent}
      title={` ${session.name} `}
      titleAlignment="center"
      padding={1}
    >
      {loading || isPending ? (
        <text fg={theme.warning}>Processing...</text>
      ) : (
        <>
          {actions.map((action, i) => (
            <box
              key={action.label}
              backgroundColor={i === selectedAction ? theme.selBg : undefined}
              paddingX={1}
              height={1}
            >
              <text fg={i === selectedAction ? theme.normal : theme.subtle}>
                {i === selectedAction ? "▶ " : "  "}{action.label}
                {action.description && i === selectedAction
                  ? <text fg={theme.muted}>{"  "}{action.description}</text>
                  : null}
              </text>
            </box>
          ))}
          <box height={1} />
          <text fg={theme.muted}>  [↑↓] Navigate  [Enter] Select  [Esc] Cancel</text>
        </>
      )}
    </box>
  )
}

// ─── New Session Form ─────────────────────────────────────────────────────────

interface NewSessionFormProps {
  onClose: () => void
  onCreated: () => void
  setStatusMessage: (msg: string, isError?: boolean) => void
}

function NewSessionForm({ onClose, onCreated, setStatusMessage }: NewSessionFormProps) {
  const [name, setName] = useState("")
  const [prdPath, setPrdPath] = useState("")
  const [focusField, setFocusField] = useState<0 | 1>(0)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState("")

  const handleSubmit = useCallback(async () => {
    if (!name.trim()) { setError("Session name is required"); return }
    if (!prdPath.trim()) { setError("PRD path is required"); return }
    setLoading(true)
    setError("")
    setStatusMessage("Creating session...")
    try {
      const { exitCode, stderr } = await runTarvosCommand(["init", prdPath.trim(), "--name", name.trim(), "--no-preview"])
      if (exitCode === 0) {
        setStatusMessage(`✓ Session '${name}' created`, false)
        onCreated()
        onClose()
      } else {
        const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
        setError(`tarvos init failed${detail}`)
        setStatusMessage("")
      }
    } catch (e) {
      setError(`Error: ${e}`)
      setStatusMessage("")
    } finally {
      setLoading(false)
    }
  }, [name, prdPath, onClose, onCreated, setStatusMessage])

  useKeyboard((key) => {
    if (loading) return
    if (key.name === "escape") { onClose(); return }
    if (key.name === "tab") {
      setFocusField(f => (f === 0 ? 1 : 0))
      return
    }
    if (key.name === "return" && focusField === 1) {
      handleSubmit()
      return
    }
  })

  return (
    <box
      position="absolute"
      top={4}
      left={4}
      width={60}
      flexDirection="column"
      backgroundColor={theme.panelBg}
      border
      borderStyle="rounded"
      borderColor={theme.info}
      title=" New Session "
      titleAlignment="center"
      padding={1}
      gap={1}
    >
      {loading ? (
        <text fg={theme.warning}>Creating session...</text>
      ) : (
        <>
          <box flexDirection="row" gap={1} alignItems="center">
            <text fg={theme.muted}>Name:    </text>
            <input
              value={name}
              onChange={setName}
              placeholder="session-name"
              focused={focusField === 0}
              width={40}
              backgroundColor="#1a1a1a"
              textColor={theme.normal}
              cursorColor={theme.accent}
              focusedBackgroundColor="#2a2a2a"
            />
          </box>
          <box flexDirection="row" gap={1} alignItems="center">
            <text fg={theme.muted}>PRD path:</text>
            <input
              value={prdPath}
              onChange={setPrdPath}
              placeholder="prds/my-feature.prd.md"
              focused={focusField === 1}
              width={40}
              backgroundColor="#1a1a1a"
              textColor={theme.normal}
              cursorColor={theme.accent}
              focusedBackgroundColor="#2a2a2a"
            />
          </box>
          {error ? (
            <text fg={theme.error}>{error}</text>
          ) : null}
          <text fg={theme.muted}>  [Tab] Next field  [Enter] Submit  [Esc] Cancel</text>
        </>
      )}
    </box>
  )
}

// ─── Footer ───────────────────────────────────────────────────────────────────

interface FooterProps {
  statusMessage: string
  statusIsError: boolean
  sessionCount: number
}

function Footer({ statusMessage, statusIsError, sessionCount }: FooterProps) {
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
      ) : (
        <text fg={theme.muted}>
          [n] New  [Enter] Actions  [j/k] Navigate  [R] Refresh  [q] Quit
        </text>
      )}
      <box flexGrow={1} />
      <text fg={theme.subtle}>{sessionCount} session{sessionCount !== 1 ? "s" : ""}</text>
    </box>
  )
}

// ─── SessionListScreen ────────────────────────────────────────────────────────

interface SessionListScreenProps {
  onNavigate: (sessionName: string) => void
  onViewSummary: (sessionName: string) => void
}

export function SessionListScreen({ onNavigate, onViewSummary }: SessionListScreenProps) {
  const renderer = useRenderer()
  const [sessions, setSessions] = useState<Session[]>([])
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [showOverlay, setShowOverlay] = useState(false)
  const [showNewForm, setShowNewForm] = useState(false)
  const [statusMessage, setStatusMessageRaw] = useState("")
  const [statusIsError, setStatusIsError] = useState(false)
  const [showRejectConfirmQuick, setShowRejectConfirmQuick] = useState(false)
  const [showForgetConfirmQuick, setShowForgetConfirmQuick] = useState(false)
  const [loading, setLoading] = useState(true)
  // 2.2 Pending actions guard: track sessions with in-flight actions
  const [pendingActions, setPendingActions] = useState<Set<string>>(new Set())

  const setStatusMessage = useCallback((msg: string, isError?: boolean) => {
    setStatusMessageRaw(msg)
    setStatusIsError(isError === true)
  }, [])

  const handlePendingStart = useCallback((sessionName: string) => {
    setPendingActions(prev => new Set(prev).add(sessionName))
  }, [])

  const handlePendingEnd = useCallback((sessionName: string) => {
    setPendingActions(prev => {
      const next = new Set(prev)
      next.delete(sessionName)
      return next
    })
  }, [])

  const refresh = useCallback(async () => {
    try {
      const loaded = await loadSessions()
      setSessions(loaded)
      setSelectedIndex(i => Math.min(i, Math.max(0, loaded.length - 1)))
    } catch {
      setStatusMessage("Failed to load sessions", true)
    } finally {
      setLoading(false)
    }
  }, [setStatusMessage])

  // 2.1 Optimistic accept removal: remove session immediately on accept
  const handleAcceptSucceeded = useCallback((sessionName: string) => {
    setSessions(s => s.filter(x => x.name !== sessionName))
  }, [])

  // 2.3 Immediate refresh after actions
  const handleActionCompleted = useCallback(() => {
    refresh()
  }, [refresh])

  // Initial load
  useEffect(() => {
    refresh()
  }, [refresh])

  // Auto-refresh every 3 seconds
  useEffect(() => {
    const id = setInterval(refresh, 3000)
    return () => clearInterval(id)
  }, [refresh])

  // 2.4 Session directory watcher for near-instant status updates
  useEffect(() => {
    let watcher: fs.FSWatcher | null = null
    try {
      watcher = fs.watch(TARVOS_SESSIONS_DIR, { recursive: true }, () => {
        refresh()
      })
    } catch {
      // Directory may not exist yet — watcher will be absent, fall back to poll
    }
    return () => {
      watcher?.close()
    }
  }, [refresh])

  // Clear status message after 4 seconds
  useEffect(() => {
    if (!statusMessage) return
    const id = setTimeout(() => setStatusMessageRaw(""), 4000)
    return () => clearTimeout(id)
  }, [statusMessage])

  const handleRejectQuick = useCallback(async () => {
    const session = sessions[selectedIndex]
    if (!session) return
    setShowRejectConfirmQuick(false)
    handlePendingStart(session.name)
    const { exitCode, stderr } = await runTarvosCommand(["reject", "--force", session.name])
    handlePendingEnd(session.name)
    if (exitCode === 0) {
      setStatusMessage(`✓ Rejected ${session.name}`, false)
      refresh()
    } else {
      const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
      setStatusMessage(`✗ Reject failed${detail}`, true)
    }
  }, [sessions, selectedIndex, refresh, setStatusMessage, handlePendingStart, handlePendingEnd])

  const handleForgetQuick = useCallback(async () => {
    const session = sessions[selectedIndex]
    if (!session) return
    setShowForgetConfirmQuick(false)
    handlePendingStart(session.name)
    const { exitCode, stderr } = await runTarvosCommand(["forget", "--force", session.name])
    handlePendingEnd(session.name)
    if (exitCode === 0) {
      setStatusMessage(`✓ Forgotten ${session.name} — branch stays in your repo`, false)
      refresh()
    } else {
      const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
      setStatusMessage(`✗ Forget failed${detail}`, true)
    }
  }, [sessions, selectedIndex, refresh, setStatusMessage, handlePendingStart, handlePendingEnd])

  // Keyboard handler — only when no overlay is open
  useKeyboard((key) => {
    if (showOverlay || showNewForm) return

    // Let confirm dialogs handle keys when open
    if (showRejectConfirmQuick || showForgetConfirmQuick) return

    if (key.name === "q" || (key.ctrl && key.name === "c")) {
      renderer.destroy()
      return
    }
    if (key.name === "j" || key.name === "down") {
      setSelectedIndex(i => Math.min(i + 1, sessions.length - 1))
      return
    }
    if (key.name === "k" || key.name === "up") {
      setSelectedIndex(i => Math.max(i - 1, 0))
      return
    }
    if (key.name === "return" && sessions.length > 0) {
      setShowOverlay(true)
      return
    }
    if (key.name === "n") {
      setShowNewForm(true)
      return
    }
    if (key.name === "R" || (key.shift && key.name === "r")) {
      refresh()
      setStatusMessage("Refreshed")
      return
    }
    // Quick actions
    const session = sessions[selectedIndex]
    if (!session) return
    // Guard: skip quick actions for sessions with in-flight operations
    if (pendingActions.has(session.name)) return
    if (key.name === "s" && session.status === "initialized") {
      handlePendingStart(session.name)
      runTarvosCommand(["begin", "--detach", session.name]).then(({ exitCode, stderr }) => {
        handlePendingEnd(session.name)
        if (exitCode === 0) {
          setStatusMessage(`✓ Started ${session.name}`, false)
        } else {
          const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
          setStatusMessage(`✗ Start failed${detail}`, true)
        }
        refresh()  // 2.3 immediate refresh after begin
      })
      return
    }
    if (key.name === "a" && session.status === "done") {
      handlePendingStart(session.name)
      runTarvosCommand(["accept", session.name]).then(({ exitCode, stderr }) => {
        handlePendingEnd(session.name)
        if (exitCode === 0) {
          setStatusMessage(`✓ Accepted ${session.name}`, false)
          // 2.1 Optimistic removal: remove immediately
          handleAcceptSucceeded(session.name)
        } else {
          const detail = stderr ? `: ${stderr}` : ` (exit ${exitCode})`
          setStatusMessage(`✗ Accept failed${detail}`, true)
        }
        refresh()  // 2.3 immediate refresh after accept
      })
      return
    }
    if (key.name === "r") {
      // Show confirmation before rejecting
      setShowRejectConfirmQuick(true)
      return
    }
    if (key.name === "f" && (session.status === "done" || session.status === "failed")) {
      setShowForgetConfirmQuick(true)
      return
    }
  })

  const selectedSession = sessions[selectedIndex]

  return (
    <box flexDirection="column" width="100%" height="100%" backgroundColor="#1C1C1C">
      <Header sessions={sessions} />
      {loading ? (
        <box flexGrow={1} justifyContent="center" alignItems="center">
          <text fg={theme.muted}>Loading sessions...</text>
        </box>
      ) : (
        <SessionTable sessions={sessions} selectedIndex={selectedIndex} />
      )}
      <Footer
        statusMessage={statusMessage}
        statusIsError={statusIsError}
        sessionCount={sessions.length}
      />

      {/* Action overlay */}
      {showOverlay && selectedSession ? (
        <ActionOverlay
          session={selectedSession}
          onClose={() => setShowOverlay(false)}
          onNavigate={onNavigate}
          onViewSummary={onViewSummary}
          setStatusMessage={setStatusMessage}
          onRejectSucceeded={refresh}
          onAcceptSucceeded={handleAcceptSucceeded}
          onActionCompleted={handleActionCompleted}
          pendingActions={pendingActions}
          onPendingStart={handlePendingStart}
          onPendingEnd={handlePendingEnd}
        />
      ) : null}

      {/* New session form */}
      {showNewForm ? (
        <NewSessionForm
          onClose={() => setShowNewForm(false)}
          onCreated={refresh}
          setStatusMessage={setStatusMessage}
        />
      ) : null}

      {/* Quick reject confirmation */}
      {showRejectConfirmQuick && selectedSession ? (
        <RejectConfirmDialog
          sessionName={selectedSession.name}
          onConfirm={handleRejectQuick}
          onCancel={() => setShowRejectConfirmQuick(false)}
        />
      ) : null}

      {/* Quick forget confirmation */}
      {showForgetConfirmQuick && selectedSession ? (
        <ForgetConfirmDialog
          sessionName={selectedSession.name}
          branchName={selectedSession.branch}
          onConfirm={handleForgetQuick}
          onCancel={() => setShowForgetConfirmQuick(false)}
        />
      ) : null}
    </box>
  )
}
