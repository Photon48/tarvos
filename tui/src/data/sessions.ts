import { join } from "path"
import type { Session } from "../types"

const TARVOS_DIR = join(process.cwd(), ".tarvos", "sessions")

export async function loadSessions(): Promise<Session[]> {
  const sessions: Session[] = []
  try {
    const glob = new Bun.Glob("*/state.json")
    for await (const file of glob.scan(TARVOS_DIR)) {
      const text = await Bun.file(join(TARVOS_DIR, file)).text()
      sessions.push(JSON.parse(text))
    }
    sessions.sort((a, b) =>
      new Date(b.last_activity).getTime() - new Date(a.last_activity).getTime()
    )
  } catch {}
  return sessions
}

export function getSessionDir(name: string): string {
  return join(TARVOS_DIR, name)
}
