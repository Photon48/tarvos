import { useState, useEffect } from "react"
import { theme } from "../theme"

// ─── Owl Mascot Component ─────────────────────────────────────────────────────
//
// Animated ASCII owl. State drives expression:
//   idle    – slow blink every 2s (2-frame cycle)
//   working – fast frame cycle 150ms (2 frames)
//   done    – static happy face
//   error   – static error face

export type OwlState = "idle" | "working" | "done" | "error"

// Each state is an array of single-line ASCII frames (compact, inline style)
const OWL_FRAMES: Record<OwlState, string[]> = {
  idle:    ["(oo)", "(--)" ],
  working: ["(*o*)", "(*_*)"],
  done:    ["(^^)"],
  error:   ["(xx)"],
}

const OWL_INTERVALS: Record<OwlState, number> = {
  idle:    2000,
  working: 150,
  done:    0,   // static – no cycling
  error:   0,   // static – no cycling
}

interface OwlProps {
  state?: OwlState
  /** If true, renders a slightly wider "full" variant (default is compact inline) */
  full?: boolean
}

export function Owl({ state = "idle", full = false }: OwlProps) {
  const frames = OWL_FRAMES[state]
  const interval = OWL_INTERVALS[state]

  const [frameIndex, setFrameIndex] = useState(0)

  useEffect(() => {
    setFrameIndex(0)
    if (interval === 0 || frames.length <= 1) return
    const id = setInterval(() => {
      setFrameIndex(i => (i + 1) % frames.length)
    }, interval)
    return () => clearInterval(id)
  }, [state, interval, frames.length])

  const face = frames[frameIndex] ?? frames[0]

  const color =
    state === "idle"    ? theme.owl.idle
    : state === "working" ? theme.owl.working
    : state === "done"    ? theme.owl.done
    : theme.owl.error

  if (full) {
    // Multi-line full owl (3 rows: face, body, feet)
    const bodyFrames: Record<OwlState, string[][]> = {
      idle:    [["(  oo  )", "( >  < )", "/|    |\\"], ["(  --  )", "( >  < )", "/|    |\\"]],
      working: [["( *oo* )", "( >@@< )", "/|    |\\"], ["( *o_* )", "( >@_< )", "/|    |\\"]],
      done:    [["(  ^^  )", "( >  < )", "/|    |\\"]],
      error:   [["(  xx  )", "( >  < )", "/|    |\\"]],
    }
    const bodyFrame = bodyFrames[state][frameIndex % bodyFrames[state].length]
    return (
      <box flexDirection="column" alignItems="center">
        <text fg={color}>{bodyFrame[0]}</text>
        <text fg={color}>{bodyFrame[1]}</text>
        <text fg={color}>{bodyFrame[2]}</text>
      </box>
    )
  }

  // Compact inline: just the face glyph
  return <text fg={color}>{face}</text>
}
