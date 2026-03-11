import { join } from "path"

const TARVOS_SCRIPT = join(import.meta.dir, "../../tarvos.sh")

export async function runTarvosCommand(
  args: string[],
  onOutput?: (line: string) => void
): Promise<{ exitCode: number }> {
  const proc = Bun.spawn(["bash", TARVOS_SCRIPT, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  })
  if (onOutput) {
    const reader = proc.stdout.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
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
  await proc.exited
  return { exitCode: proc.exitCode ?? 1 }
}
