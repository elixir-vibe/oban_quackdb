%{
  configs: [
    %{
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {ExSlop.Check.Readability.NarratorDoc, false}
      ],
      plugins: [{ExSlop, []}],
      name: "default"
    }
  ]
}
