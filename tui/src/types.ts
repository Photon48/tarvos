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
  created_at: string
  started_at: string | null
  last_activity: string
  loop_count: number
  final_signal: string | null
}

export interface TuiEvent {
  type: string        // "tool_use" | "text" | "signal" | "status" | etc.
  content?: string
  tool?: string
  tokens?: number
  phase?: string
  signal?: string
  timestamp?: string
  raw?: string
}
