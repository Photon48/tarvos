import { useState, useEffect, useCallback } from "react"
import { useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/react"
import { theme } from "../theme"
import { getSessionDir } from "../data/sessions"
import { join } from "path"
import { watch } from "fs"

// ─── Header ───────────────────────────────────────────────────────────────────

interface HeaderProps {
  sessionName: string
}

function Header({ sessionName }: HeaderProps) {
  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.headerBg}
      paddingX={2}
      paddingY={0}
      height={1}
    >
      <text fg={theme.accent}>
        <strong>TARVOS</strong>
      </text>
      <text fg={theme.normal}> — Summary: </text>
      <text fg={theme.info}>{sessionName}</text>
    </box>
  )
}

// ─── Footer ───────────────────────────────────────────────────────────────────

function Footer() {
  return (
    <box
      flexDirection="row"
      width="100%"
      backgroundColor={theme.panelBg}
      paddingX={2}
      height={1}
    >
      <text fg={theme.muted}>
        [Enter/q] Back  [s] Open file  [↑↓] Scroll
      </text>
    </box>
  )
}

// ─── Summary Content ──────────────────────────────────────────────────────────

interface SummaryContentProps {
  content: string
  isGenerating: boolean
  height: number
  scrollOffset: number
}

function SummaryContent({ content, isGenerating, height, scrollOffset }: SummaryContentProps) {
  if (isGenerating) {
    return (
      <box
        flexGrow={1}
        justifyContent="center"
        alignItems="center"
      >
        <text fg={theme.warning}>Generating summary...</text>
      </box>
    )
  }

  const lines = content.split("\n")
  const maxScroll = Math.max(0, lines.length - height)
  const clampedOffset = Math.min(scrollOffset, maxScroll)
  const visibleLines = lines.slice(clampedOffset, clampedOffset + height)

  return (
    <box
      border
      borderStyle="rounded"
      borderColor={theme.success}
      flexGrow={1}
      flexDirection="column"
      paddingX={1}
    >
      <scrollbox flexGrow={1}>
        {visibleLines.map((line, i) => (
          <text key={i} fg={theme.normal}>{line || " "}</text>
        ))}
      </scrollbox>
    </box>
  )
}

// ─── SummaryScreen ─────────────────────────────────────────────────────────────

interface SummaryScreenProps {
  sessionName: string
  onBack: () => void
}

export function SummaryScreen({ sessionName, onBack }: SummaryScreenProps) {
  const renderer = useRenderer()
  const { height } = useTerminalDimensions()
  const [content, setContent] = useState("")
  const [isGenerating, setIsGenerating] = useState(true)
  const [scrollOffset, setScrollOffset] = useState(0)

  const sessionDir = getSessionDir(sessionName)
  const summaryPath = join(sessionDir, "summary.md")

  // Compute visible content height (minus header + footer + border)
  const contentHeight = Math.max(5, height - 4)

  const loadSummary = useCallback(async () => {
    try {
      const file = Bun.file(summaryPath)
      const exists = await file.exists()
      if (!exists) {
        setIsGenerating(true)
        setContent("")
        return
      }
      const text = await file.text()
      if (!text.trim()) {
        setIsGenerating(true)
        setContent("")
        return
      }
      setIsGenerating(false)
      setContent(text)
      // Auto-scroll to bottom when new content arrives (if already near bottom)
      setScrollOffset(prev => {
        const lines = text.split("\n").length
        const maxScroll = Math.max(0, lines - contentHeight)
        // If user hasn't scrolled up, stay at top (summary reads top-down)
        return prev > maxScroll ? maxScroll : prev
      })
    } catch {
      setIsGenerating(true)
    }
  }, [summaryPath, contentHeight])

  // Initial load
  useEffect(() => {
    loadSummary()
  }, [loadSummary])

  // Watch for file changes (live streaming as file grows)
  useEffect(() => {
    let watcher: ReturnType<typeof watch> | null = null
    try {
      watcher = watch(summaryPath, { persistent: false }, () => {
        loadSummary()
      })
    } catch {
      // File may not exist yet — watch the parent directory instead
      try {
        watcher = watch(sessionDir, { persistent: false }, (_, filename) => {
          if (filename === "summary.md") {
            loadSummary()
            // Re-attach watcher directly to file once it exists
          }
        })
      } catch {
        // Directory doesn't exist either — poll as fallback
      }
    }
    return () => {
      watcher?.close()
    }
  }, [summaryPath, sessionDir, loadSummary])

  // Poll every 2s as a fallback while still generating
  useEffect(() => {
    if (!isGenerating) return
    const id = setInterval(loadSummary, 2000)
    return () => clearInterval(id)
  }, [isGenerating, loadSummary])

  useKeyboard((key) => {
    if (key.name === "return" || key.name === "q") {
      onBack()
      return
    }
    if (key.ctrl && key.name === "c") {
      renderer.destroy()
      return
    }
    if (key.name === "up" || key.name === "k") {
      setScrollOffset(prev => Math.max(0, prev - 1))
      return
    }
    if (key.name === "down" || key.name === "j") {
      setScrollOffset(prev => {
        const lines = content.split("\n").length
        const maxScroll = Math.max(0, lines - contentHeight)
        return Math.min(prev + 1, maxScroll)
      })
      return
    }
    if (key.name === "s") {
      // Open file with system default viewer (macOS open / $EDITOR fallback)
      const editor = process.env.EDITOR
      if (editor) {
        Bun.spawn([editor, summaryPath])
      } else {
        Bun.spawn(["open", summaryPath])
      }
      return
    }
  })

  return (
    <box flexDirection="column" width="100%" height="100%" backgroundColor="#1C1C1C">
      <Header sessionName={sessionName} />
      <SummaryContent
        content={content}
        isGenerating={isGenerating}
        height={contentHeight}
        scrollOffset={scrollOffset}
      />
      <Footer />
    </box>
  )
}
