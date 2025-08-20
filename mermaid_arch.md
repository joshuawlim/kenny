```mermaid
flowchart TB

%% UI
subgraph UI["Invocation and UX"]
  ui_cli[Raycast or Alfred CLI 'assistant']
  ui_menu[Menu Bar Status Week 9 optional]
end

%% Orchestrator
subgraph Orchestrator["Orchestrator Planner - Confirm - Execute"]
  orch_planner[Planner rule-based then local 7-8B fc]
  orch_validator[Validator and Policy schemas, allowlists, PII guards]
  orch_executor[Executor idempotent, retries, compensation]
  orch_queue[Job Queue Week 7]
end

%% Tools
subgraph Tools["mac_tools Swift CLI, JSON IO"]
  t_calendar[calendar_list]
  t_mail[mail_list_headers]
  t_reminders[reminders_create --dry-run --confirm]
  t_notes[notes_append --dry-run --confirm]
  t_files[files_move --dry-run --confirm]
  t_tcc[tcc_request]
end

%% Data and Index
subgraph Data["Local Data and Index"]
  db_main[SQLite + FTS5 emails/events/reminders/notes/files provenance, tombstones, WAL]
  ingest_jobs[Ingest: full and delta hash or etag, last_seen, deletes]
  retrieval[Hybrid Retrieval BM25 first, local embeddings Week 3]
end

%% Logs and Audit
subgraph Logs["Observability and Audit"]
  log_tools[Tool NDJSON logs ~/Library/Logs/Assistant/tools.ndjson]
  log_runs[Orchestrator run logs structured JSON]
  log_audits[Audit bundles per run plan.json, confirm.json, tool_calls.json, timings.json]
end