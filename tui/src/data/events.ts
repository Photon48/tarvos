import { join } from "path"
import { watch } from "fs"
import type { TuiEvent } from "../types"

export function watchEventsFile(
  sessionDir: string,
  loopNum: number,
  onEvent: (event: TuiEvent) => void
): () => void {
  const file = join(sessionDir, `events-${loopNum}.jsonl`)
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

  const watcher = watch(file, { persistent: false }, drain)
  drain() // Initial drain
  return () => watcher.close()
}
