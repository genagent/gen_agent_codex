defmodule GenAgent.Backends.Codex.EventTranslatorTest do
  use ExUnit.Case, async: true

  alias CodexWrapper.JsonLineEvent
  alias GenAgent.Backends.Codex.EventTranslator
  alias GenAgent.Event

  defp event(type, data), do: %JsonLineEvent{event_type: type, data: data, raw: ""}

  describe "thread_id capture" do
    test "injects thread_id from thread.started into the :result event as session_id" do
      events = [
        event("thread.started", %{"thread_id" => "thread-abc", "type" => "thread.started"}),
        event("turn.started", %{"type" => "turn.started"}),
        event("item.completed", %{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "hi"}
        }),
        event("turn.completed", %{
          "type" => "turn.completed",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
        })
      ]

      translated = EventTranslator.translate(events)

      assert [
               %Event{kind: :text, data: %{text: "hi"}},
               %Event{kind: :usage, data: %{input_tokens: 10, output_tokens: 2}},
               %Event{kind: :result, data: %{session_id: "thread-abc"}}
             ] = translated
    end

    test "emits a :result event with nil session_id when thread.started is missing" do
      events = [
        event("turn.completed", %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}})
      ]

      translated = EventTranslator.translate(events)

      assert [
               %Event{kind: :usage},
               %Event{kind: :result, data: data}
             ] = translated

      refute Map.has_key?(data, :session_id)
    end
  end

  describe "item.completed translation" do
    test "agent_message becomes :text" do
      events = [
        event("item.completed", %{
          "item" => %{"type" => "agent_message", "text" => "hello world"}
        }),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :text, data: %{text: "hello world"}}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "tool_call becomes :tool_use with the whole item as data" do
      item = %{"type" => "tool_call", "id" => "t1", "name" => "bash", "input" => %{}}
      events = [event("item.completed", %{"item" => item}), event("turn.completed", %{})]

      assert [%Event{kind: :tool_use, data: ^item}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "tool_result becomes :tool_result" do
      item = %{"type" => "tool_result", "output" => "file1\nfile2"}
      events = [event("item.completed", %{"item" => item}), event("turn.completed", %{})]

      assert [%Event{kind: :tool_result, data: ^item}, %Event{kind: :result}] =
               EventTranslator.translate(events)
    end

    test "unknown item types are filtered out" do
      events = [
        event("item.completed", %{"item" => %{"type" => "mystery"}}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end
  end

  describe "turn.completed" do
    test "emits :usage when token counts are present" do
      events = [
        event("turn.completed", %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cached_input_tokens" => 80
          }
        })
      ]

      assert [
               %Event{
                 kind: :usage,
                 data: %{input_tokens: 100, output_tokens: 50, cached_input_tokens: 80}
               },
               %Event{kind: :result}
             ] = EventTranslator.translate(events)
    end

    test "skips :usage when no token counts are present" do
      events = [event("turn.completed", %{})]
      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end
  end

  describe "error events" do
    test "turn.failed becomes a terminal :error" do
      events = [
        event("thread.started", %{"thread_id" => "t-1"}),
        event("turn.failed", %{"error" => "rate limited"})
      ]

      assert [%Event{kind: :error, data: %{reason: "rate limited"}}] =
               EventTranslator.translate(events)
    end

    test "plain error event" do
      events = [event("error", %{"message" => "network down"})]

      assert [%Event{kind: :error, data: %{reason: "network down"}}] =
               EventTranslator.translate(events)
    end

    test "error with neither field falls back to :unknown" do
      assert [%Event{kind: :error, data: %{reason: :unknown}}] =
               EventTranslator.translate([event("error", %{})])
    end
  end

  describe "filtered events" do
    test "turn.started is filtered" do
      events = [event("turn.started", %{}), event("turn.completed", %{})]
      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end

    test "unknown event types are filtered" do
      events = [
        event("mystery.event", %{"foo" => "bar"}),
        event("turn.completed", %{})
      ]

      assert [%Event{kind: :result}] = EventTranslator.translate(events)
    end
  end
end
