import { join } from "path"

// In compiled Bun binaries, import.meta.dir resolves to "/" (embedded VFS root),
// so the relative path breaks.  tarvos.sh exports TARVOS_SCRIPT_DIR before
// launching the TUI; fall back to import.meta.dir for dev mode (bun run).
const TARVOS_SCRIPT = process.env.TARVOS_SCRIPT_DIR
  ? join(process.env.TARVOS_SCRIPT_DIR, "tarvos.sh")
  : join(import.meta.dir, "../../tarvos.sh")

export async function runTarvosCommand(
  args: string[],
  onOutput?: (line: string) => void
): Promise<{ exitCode: number; stderr: string }> {
  const proc = Bun.spawn(["bash", TARVOS_SCRIPT, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  })

  let stderrOutput = ""

  const errReader = proc.stderr.getReader()
  const readErr = async () => {
    const decoder = new TextDecoder()
    while (true) {
      const { done, value } = await errReader.read()
      if (done) break
      stderrOutput += decoder.decode(value, { stream: true })
    }
  }

  if (onOutput) {
    const reader = proc.stdout.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    const readOut = async () => {
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          buffer += decoder.decode(value, { stream: true })
          const lines = buffer.split("\n")
          buffer = lines.pop() ?? ""
          for (const line of lines) {
            if (line) onOutput(line)
          }
        }
        if (buffer) onOutput(buffer)
      } catch {}
    }
    await Promise.all([readOut(), readErr(), proc.exited])
  } else {
    await Promise.all([readErr(), proc.exited])
  }

  return { exitCode: proc.exitCode ?? 1, stderr: stderrOutput.trim() }
}
