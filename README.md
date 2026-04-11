# GenAgentCodex

[![CI](https://github.com/genagent/gen_agent_codex/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/gen_agent_codex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gen_agent_codex.svg)](https://hex.pm/packages/gen_agent_codex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gen_agent_codex)

Codex backend for [GenAgent](https://github.com/genagent/gen_agent),
built on top of [codex_wrapper](https://hex.pm/packages/codex_wrapper).

Provides `GenAgent.Backends.Codex`, which wraps the `codex` CLI and
translates its NDJSON event output into the normalized `GenAgent.Event`
values the state machine consumes.

## Prerequisites

The `codex` CLI must be installed and on your `PATH`. See the
[Codex docs](https://github.com/openai/codex) for install instructions.

## Installation

```elixir
def deps do
  [
    {:gen_agent, "~> 0.2.0"},
    {:gen_agent_codex, "~> 0.1.0"}
  ]
end
```

## Quick start

```elixir
defmodule MyApp.Coder do
  use GenAgent

  defmodule State do
    defstruct [:path, responses: []]
  end

  @impl true
  def init_agent(opts) do
    path = Keyword.fetch!(opts, :cwd)

    backend_opts = [
      cwd: path,
      sandbox: :read_only,
      skip_git_repo_check: true
    ]

    {:ok, backend_opts, %State{path: path}}
  end

  @impl true
  def handle_response(_ref, response, state) do
    {:noreply, %{state | responses: state.responses ++ [response.text]}}
  end
end

{:ok, _pid} = GenAgent.start_agent(MyApp.Coder,
  name: "my-coder",
  backend: GenAgent.Backends.Codex,
  cwd: "/path/to/project"
)

{:ok, response} = GenAgent.ask("my-coder", "What does lib/foo.ex do?")
IO.puts(response.text)
```

## Session continuation

Codex tracks conversation state via a server-side `thread_id`. The backend
captures it from the first `thread.started` event of a turn and threads it
through `codex exec resume` on subsequent turns -- transparently, no caller
code required.

```elixir
{:ok, r1} = GenAgent.ask("my-coder", "Remember the number 42")
{:ok, r2} = GenAgent.ask("my-coder", "What number did I ask you to remember?")
# r2.text == "42"
```

## Why this backend uses `exec_json` instead of streaming

`CodexWrapper.Exec.stream/2` and `CodexWrapper.ExecResume.stream/2` were
historically broken against `codex-cli >= 0.118` due to a Port+stdin hang
(see [codex_wrapper#37](https://github.com/genagent/codex_wrapper_ex/issues/37),
fixed in codex_wrapper 0.2.2). Even after the fix, this backend still
uses the non-streaming `Exec.execute_json/2` path because:

- GenAgent's prompt task blocks on the whole turn anyway -- the caller
  waits for a full `GenAgent.Response` regardless.
- `handle_stream_event/2` still fires for every event in arrival order,
  just all at once when `exec_json` returns instead of progressively.
- The path is simpler and has fewer moving parts.

If you need real-time streaming events before the turn completes, you
can provide your own `:exec_fn` that calls `Exec.stream/2` (which now
works) and wrap it in something that yields events over time.

## Backend options

**Config:**
- `:binary`, `:working_dir` (aliased as `:cwd`), `:env`, `:timeout`,
  `:verbose`

**Exec:**
- `:model`, `:sandbox`, `:approval_policy`, `:full_auto`,
  `:dangerously_bypass_approvals_and_sandbox`, `:skip_git_repo_check`,
  `:ephemeral`, `:cd`, `:add_dirs`, `:search`, `:output_schema`,
  `:config_overrides`, `:enabled_features`, `:disabled_features`,
  `:images`

**Backend-only:**
- `:exec_fn` -- a 2-arity function `(prompt, session) -> {:ok, [events]} | {:error, term()}`
  that replaces the default `Exec`/`ExecResume` dispatch. Intended for tests.

Codex has no equivalent of Claude's `--system-prompt`; if you need
system-level instructions, pass them via `AGENTS.md` in the working
directory or through Codex's configuration layer.

See `GenAgent.Backends.Codex` for the full module docs.

## Event translation

Codex CLI's NDJSON output is translated into `GenAgent.Event` values by
`GenAgent.Backends.Codex.EventTranslator`:

| Codex event | GenAgent event |
|---|---|
| `thread.started` | captured for `thread_id`, then filtered |
| `turn.started` | filtered |
| `item.completed` (`agent_message`) | `:text` |
| `item.completed` (`tool_call`) | `:tool_use` |
| `item.completed` (`tool_result`) | `:tool_result` |
| `turn.completed` | `:usage` + terminal `:result` (with captured `thread_id` as `session_id`) |
| `turn.failed` / `error` | terminal `:error` |
| anything else | filtered |

Unlike Claude, Codex emits `thread_id` in the **first** event of a turn,
not the terminal one. The translator does a first pass to extract it and
injects it into the `:result` event emitted at the end.

## Testing

```bash
# Unit tests only (default, no CLI invocation)
mix test

# Include live integration tests that actually call the codex CLI
mix test --only integration
```

Integration tests are tagged `:integration` so they do not run by
default. They burn real tokens -- keep them cheap.

## License

MIT. See [LICENSE](LICENSE).
