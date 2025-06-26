%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["apps/*/lib/", "apps/*/test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      color: true,
      requires: ["./lib/arbor/credo/checks/"],
      checks: [
        # Custom Architectural Guardrails for Arbor's Dual-Contract System
        #
        # These checks enforce Arbor's architectural principles:
        # 1. All public modules must implement behavior contracts from arbor_contracts
        # 2. All behavior callbacks must be marked with @impl true
        # 3. Behavior definitions (@callback) must only exist in arbor_contracts
        #
        # This ensures clean separation of contracts and implementations while
        # maintaining the dual-contract system (TypedStruct + Behaviors)
        #
        {Arbor.Credo.Check.ContractEnforcement, [
          excluded_patterns: ["Test", "Mock", "Stub", "Support"],
          require_impl: true
        ]},
        {Arbor.Credo.Check.ImplTrueEnforcement, [
          strict: true
        ]},
        {Arbor.Credo.Check.BehaviorLocationCheck, [
          allowed_paths: ["apps/arbor_contracts/lib/"]
        ]},

        # Consistency checks - especially important for contracts
        {Credo.Check.Consistency.ExceptionNames, []},
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Consistency.SpaceAroundOperators, []},
        {Credo.Check.Consistency.SpaceInParentheses, []},
        {Credo.Check.Consistency.TabsOrSpaces, []},

        # Readability - contracts must be clear
        {Credo.Check.Readability.AliasOrder, []},
        {Credo.Check.Readability.FunctionNames, []},
        {Credo.Check.Readability.ModuleDoc, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},
        {Credo.Check.Readability.ModuleNames, []},
        {Credo.Check.Readability.PredicateFunctionNames, []},
        {Credo.Check.Readability.SinglePipe, []},
        {Credo.Check.Readability.Specs, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},
        {Credo.Check.Readability.StrictModuleLayout, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},

        # Design - ensure contracts follow best practices
        {Credo.Check.Design.AliasUsage, [priority: :low, excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},
        {Credo.Check.Design.DuplicatedCode, [mass_threshold: 40, excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},

        # Warnings - catch potential issues
        {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
        {Credo.Check.Warning.BoolOperationOnSameValues, []},
        {Credo.Check.Warning.LeakyEnvironment, []},
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
        {Credo.Check.Warning.MixEnv, []},
        {Credo.Check.Warning.OperationOnSameValues, []},
        {Credo.Check.Warning.OperationWithConstantResult, []},
        {Credo.Check.Warning.SpecWithStruct, []},
        {Credo.Check.Warning.UnsafeExec, []},
        {Credo.Check.Warning.UnusedEnumOperation, []},
        {Credo.Check.Warning.UnusedFileOperation, []},
        {Credo.Check.Warning.UnusedKeywordOperation, []},
        {Credo.Check.Warning.UnusedListOperation, []},
        {Credo.Check.Warning.UnusedPathOperation, []},
        {Credo.Check.Warning.UnusedRegexOperation, []},
        {Credo.Check.Warning.UnusedStringOperation, []},
        {Credo.Check.Warning.UnusedTupleOperation, []},

        # Disable checks that are too restrictive for contracts
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.UnlessWithElse, false},
        {Credo.Check.Refactor.WithClauses, false},

        # Architecture-specific exclusions for test backends and examples:
        # - test/ : Standard test files
        # - */mocks/ : Production backends used for in-memory testing (dependency injection)
        # - */examples/ : Demo implementations showing usage patterns
        {Credo.Check.Refactor.CyclomaticComplexity, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},
        {Credo.Check.Refactor.FunctionArity, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},
        {Credo.Check.Refactor.LongQuoteBlocks, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]},
        {Credo.Check.Refactor.MatchInCondition, [excluded_paths: ["test/", "*/mocks/", "*/examples/"]]}
      ]
    }
  ]
}
