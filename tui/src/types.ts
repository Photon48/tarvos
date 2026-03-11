export type SessionStatus = "running" | "done" | "stopped" | "failed" | "initialized"

export interface Session {
  name: string
  status: SessionStatus
  prd_file: string
  token_limit: number
  max_loops: number
  branch: string
  original_branch: string
  worktree_path: string
  log_dir: string  // path to current run's log dir, e.g. .tarvos/sessions/<n>/logs/run-<ts>
  created_at: string
  started_at: string | null
  last_activity: string
  loop_count: number
  final_signal: string | null
}

export interface TuiEvent {
  type: string        // "tool_use" | "text" | "signal" | "status" | "loop_start" | etc.
  content?: string
  tool?: string
  tokens?: number
  phase?: string
  signal?: string
  loop?: number       // present in "loop_start" events
  ts?: number         // unix timestamp from shell
  timestamp?: string
  raw?: string
}
