import { join } from "path"
import { watch, readdirSync } from "fs"
import type { TuiEvent } from "../types"

// ─── Multi-loop events watcher ──────────────────────────────────────────────
// Watches the entire logDir directory. When any file changes, re-scans for all
// loop-NNN-events.jsonl files and tails new content from each one seen so far.
// This ensures events from loop 1, 2, 3 … are all accumulated seamlessly.

export function watchLogDir(
  logDir: string,
  onEvent: (event: TuiEvent) => void
): () => void {
  // Map from loop file path → byte offset already consumed
  const offsets = new Map<string, number>()

  // Return sorted list of loop events files present in logDir
  const getLoopFiles = (): string[] => {
    try {
      const entries = readdirSync(logDir)
      return entries
        .filter(f => /^loop-\d{3}-events\.jsonl$/.test(f))
        .sort()
        .map(f => join(logDir, f))
    } catch {
      return []
    }
  }

  // Drain any new lines from a single file
  const drainFile = async (filePath: string) => {
    try {
      const text = await Bun.file(filePath).text()
      const offset = offsets.get(filePath) ?? 0
      const newContent = text.slice(offset)
      offsets.set(filePath, text.length)
      for (const line of newContent.split("\n").filter(Boolean)) {
        try { onEvent(JSON.parse(line)) } catch {}
      }
    } catch {}
  }

  // Drain all known + newly discovered loop files
  const drainAll = async () => {
    const files = getLoopFiles()
    for (const f of files) {
      await drainFile(f)
    }
  }

  // Initial drain
  drainAll()

  // Watch the directory for any changes (new files / file writes)
  let watcher: ReturnType<typeof watch> | null = null
  try {
    watcher = watch(logDir, { persistent: false, recursive: false }, (_evt, _filename) => {
      drainAll()
    })
  } catch {
    // Fallback: 1s polling if fs.watch fails (e.g., network filesystem)
    const intervalId = setInterval(drainAll, 1000)
    return () => clearInterval(intervalId)
  }

  return () => { try { watcher?.close() } catch {} }
}

// ─── Legacy single-file watcher (kept for backward compatibility) ────────────

export function watchEventsFile(
  logDir: string,
  loopNum: number,
  onEvent: (event: TuiEvent) => void
): () => void {
  const paddedLoop = String(loopNum).padStart(3, "0")
  const file = join(logDir, `loop-${paddedLoop}-events.jsonl`)
  let offset = 0

  const drain = async () => {
    try {
      const text = await Bun.file(file).text()
      const newContent = text.slice(offset)
      offset = text.length
      for (const line of newContent.split("\n").filter(Boolean)) {
        try { onEvent(JSON.parse(line)) } catch {}
      }
    } catch {}
  }

  let watcher: ReturnType<typeof watch> | null = null
  try {
    watcher = watch(file, { persistent: false }, drain)
  } catch {}
  drain() // Initial drain
  return () => { try { watcher?.close() } catch {} }
}
