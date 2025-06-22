# Arbor Framework: Post-Stabilization Strategic Plan

**Date**: 2025-06-21  
**Purpose**: To define the next phase of development for the Arbor framework following the successful completion of the foundational stabilization plan.
**Status**: Foundation Stabilization Complete. Ready for Client and Application Layer Development.

## Executive Summary

The initial asset salvage and contract enforcement initiative is **complete and successful**. All critical architectural flaws identified in the original `mcpchat_salvage.md` report have been remediated. The Arbor framework now stands on a robust, reliable, and internally consistent foundation, with its contracts-first architecture fully enforced. The core distributed orchestration engine is sound.

With the foundation stabilized, the project's focus now shifts from internal refactoring to external value delivery. The next phase will concentrate on building client interfaces, implementing meaningful agent business logic, and enhancing operational readiness through comprehensive observability.

---

## Phase 1: Foundation Stabilization - ✅ COMPLETE

This phase addressed the critical architectural and contract-drift issues that undermined the system's stability and distributed nature.

### Key Accomplishments

1.  **✅ Test Environment Fixed**: All test helper compilation issues were resolved, unblocking CI/CD and validation for all subsequent fixes.
2.  **✅ Sessions.Manager Refactored**: The critical flaw of using a local ETS table was resolved. `Sessions.Manager` now correctly uses a distributed `Horde.Registry`, enabling true cluster-wide session management. This single fix resolved four separate pre-commit findings related to scalability, monitoring, and registration.
3.  **✅ Core Contracts Enforced**: All modules, including `Arbor.Core.Gateway` and `Arbor.Core.Sessions.Manager`, now correctly implement their specified `@behaviour` and adhere to the function signatures defined in `Arbor.Contracts`. All Dialyzer warnings related to this drift have been fixed.
4.  **✅ Agent State Recovery Aligned**: The `AgentReconciler` was investigated and its role clarified. A two-tiered restart strategy (`:transient` child specs in `Horde.DynamicSupervisor` plus the `AgentReconciler` for graceful recovery) is now the documented and implemented standard, ensuring a single, coherent approach to state recovery.
5.  **✅ Session Lifecycle Policy Defined**: The operational contract for session lifecycle has been clarified and documented in the `SessionRegistry` module.
6.  **✅ Dialyzer Warnings Resolved**: All unreachable pattern warnings in HordeSupervisor registration patterns have been fixed, ensuring type-safe, mathematically correct error handling.

---

## Phase 2: Next Strategic Initiatives (Current Focus)

With a stable foundation, we can now build upon it. This phase focuses on developing the application and client layers that deliver business value.

### Priority 1: Implement the Client-Facing Architecture (CLI)

**Goal**: Build a fully functional Command-Line Interface (CLI) for interacting with the Arbor orchestration engine.
**Rationale**: The system currently has no user-facing interface. A CLI is the fastest path to enabling agent management, system monitoring, and end-to-end testing.
**Action Plan**:
1.  **Define Client Contracts**: Implement `Arbor.Contracts.Client.Command` and `Arbor.Contracts.Client.Router` as foundational interfaces for client interaction patterns.
2.  **Build CLI Application**: Create a new `arbor_cli` application, adapting proven patterns from MCP Chat (command router, base command module, renderer).
3.  **Integrate with Gateway**: Ensure all CLI commands communicate with the core system via the `Arbor.Core.Gateway`, respecting the now-enforced API contract.

### Priority 2: Develop Core Agent Business Logic

**Goal**: Move beyond stub agents and implement agents that perform meaningful work.
**Rationale**: The orchestration framework is only valuable if it orchestrates useful agents.
**Action Plan**:
1.  **Define a Use Case**: Select a simple, high-value task for the first production-grade agent.
2.  **Implement Agent Behaviour**: Create a new agent module that implements the `Arbor.Agent` behaviour to perform the defined task.
3.  **End-to-End Integration**: Use the new CLI to spawn, task, monitor, and terminate the new agent, proving the entire vertical slice works as intended.

### Priority 3: Enhance and Formalize Observability

**Goal**: Ensure the newly architected distributed system is fully observable for debugging, monitoring, and performance analysis.
**Rationale**: The foundational refactors have rendered previous telemetry obsolete. Operating a distributed system without visibility is untenable.
**Action Plan**:
1.  **Instrument Horde**: Add Telemetry events for `Horde.Registry` and `Horde.DynamicSupervisor` activities.
2.  **Instrument Reconciler**: Add Telemetry events for `AgentReconciler` operations (e.g., agent found, agent restarted).
3.  **Build Dashboards**: Create monitoring dashboards to track key cluster health metrics (e.g., node count, agents per node, reconciliation events, gateway command throughput).

### Priority 4: Automate Architectural Guardrails

**Goal**: Implement the automated checks defined in the original strategy to prevent future architectural drift.
**Rationale**: Codifying architectural rules in tooling reduces developer cognitive load and makes the system more resilient to entropy.
**Action Plan**:
1.  **Implement Credo Check**: Add the custom Credo check to enforce `@behaviour` declarations in CI.
2.  **Integrate Norm (Optional but Recommended)**: For critical boundaries like the Gateway, consider adding `Norm` for runtime validation in dev/test environments to provide fast feedback.
3.  **Build Mix Generators**: Create `mix arbor.gen.impl` to scaffold new contract implementations correctly.

## Quick Wins

*   **✅ Document Session Lifecycle Policy**: Session lifecycle has been clarified and documented in the appropriate modules.
*   **Implement the Custom Credo Check**: Add automated `@behaviour` enforcement to prevent future contract drift.
*   **Create the `mix arbor.gen.impl` Task**: Implement Mix generator for scaffolding new contract implementations correctly.

## Conclusion

The Arbor project has successfully navigated a critical phase of stabilization and technical debt repayment. The foundation is now stronger than ever. The focus for the foreseeable future is on building out from this core, delivering user-facing features, and ensuring the system is operationally excellent.

---

## Original Analysis Archive

The original analysis identified four critical categories of issues, all of which have been resolved:

### ✅ CRITICAL Issues (All Resolved)
1. **Sessions.Manager uses local ETS instead of distributed registry** - Fixed with distributed `Horde.Registry`
2. **Systemic Contract Abandonment Crisis** - Fixed with `@behaviour` declarations and adapter patterns
3. **Test Helper Compilation Issues** - Fixed with proper contract implementations

### ✅ MEDIUM Issues (All Resolved)
1. **Race condition documentation** - Documented in AgentReconciler
2. **Undefined restart strategy** - Resolved with two-tiered approach

### ✅ LOW Issues (All Resolved)
1. **TTL functionality disabled** - Documented and clarified
2. **ClusterEvents placeholder functions** - Implemented
3. **ClusterEvents cluster_id issues** - Fixed

The contract enforcement strategy has been successfully implemented, providing a stable foundation for continued development.

---

## Completed Work Summary

### Contract Enforcement Steps (All Completed)
1. ✅ **Step 1: Test Helper Compilation Issues** - Fixed missing contract implementations
2. ✅ **Step 2: Sessions.Manager Holistic Refactor** - Implemented distributed SessionRegistry 
3. ✅ **Step 3: Add Missing @behaviour Declarations** - Added contract compliance declarations
4. ✅ **Step 4: Implement Adapter Pattern** - Created adapter functions for Gateway and Sessions.Manager
5. ✅ **Step 5: AgentReconciler Investigation** - Converted to singleton and documented two-tiered restart strategy

### Additional Stabilization Work
- ✅ **Dialyzer Warning Resolution** - Fixed all unreachable pattern warnings
- ✅ **Restart Strategy Documentation** - Comprehensive architectural documentation
- ✅ **Two-Tiered Responsibility Model** - Clear separation between HordeSupervisor and AgentReconciler

**Result**: 100% of critical contract drift and architectural issues resolved. System is now ready for feature development.