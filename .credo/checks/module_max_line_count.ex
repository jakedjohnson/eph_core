defmodule CredoChecks.ModuleMaxLineCount do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :refactor,
    param_defaults: [max_lines: 300],
    explanations: [
      check: """
      Flags source files exceeding the configured line count threshold.
      Large modules should be split for maintainability.
      """
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @doc false
  def run(source_file, params \\ []) do
    max_lines = Params.get(params, :max_lines, __MODULE__)
    issue_meta = IssueMeta.for(source_file, params)
    line_count = source_file |> SourceFile.lines() |> length()

    if line_count > max_lines do
      [
        format_issue(
          issue_meta,
          message:
            "File has #{line_count} lines (max #{max_lines}). Consider splitting this module.",
          line_no: 1,
          column: 1
        )
      ]
    else
      []
    end
  end
end
