import { join } from "path"
import { watch } from "fs"
import type { TuiEvent } from "../types"

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
