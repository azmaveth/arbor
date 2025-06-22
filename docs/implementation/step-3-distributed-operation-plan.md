# ⚠️ ARCHIVED/OBSOLETE IMPLEMENTATION PLAN ⚠️

> **NOTE:** This implementation plan is **OBSOLETE** and has been **SUPERSEDED** by our current superior architecture.  
> 
> **Current Status:** Phases 1 & 2 were completed successfully, but the implementation evolved into a much better "Declarative Agent Supervision" model with:
> - Stateless HordeSupervisor (no GenServer state)
> - Agent self-registration pattern
> - AgentReconciler for self-healing capabilities
> - Agent specs stored in Horde.Registry using {:agent_spec, agent_id} keys
>
> **For current architecture information, refer to:**
> - `/docs/arbor/01-overview/architecture-overview.md` - Current architectural overview
> - Implementation code in `/apps/arbor_core/lib/arbor/core/` - Source of truth for current design
> - `/docs/arbor/07-implementation/phase-2-production.md` - Updated implementation plan
>
> This document is preserved for historical reference only.

---

# Step 3: Enable Distributed Operation with Horde - Implementation Plan

## Overview

This document tracks the implementation of Step 3 from the Arbor roadmap. The goal is to enable true distributed operation using Horde for cluster-wide agent management.

## Critical Issue Identified

**Root Cause**: HordeRegistry is using local GenServer state instead of Horde.Registry, preventing any distributed functionality from working. This must be fixed first.

## Implementation Phases

### Phase 1: Fix HordeRegistry ⚠️ CRITICAL - MUST DO FIRST

**Status**: 🔴 Not Started  
**Blocker**: This blocks ALL other distributed functionality

#### Tasks:
- [ ] Remove GenServer behavior from HordeRegistry
- [ ] Remove local state management (defstruct with :ttl_timers, :group_memberships, :pid_mappings)
- [ ] Add Horde.Registry to application supervision tree
- [ ] Update register_name/3 to use Horde.Registry.register/3
- [ ] Update lookup_name/2 to use Horde.Registry.lookup/2
- [ ] Update unregister_name/2 to use Horde.Registry.unregister/2
- [ ] Fix PID registration to track actual agent PIDs (not supervisor PIDs)
- [ ] Implement TTL functionality with distributed state
- [ ] Update group membership functions for distributed operation
- [ ] Add proper error handling for distributed operations
- [ ] Update tests to work with distributed registry

### Phase 2: Implement Automatic Failover

**Status**: 🔴 Not Started  
**Depends on**: Phase 1 completion

#### Tasks:
- [ ] Verify Horde.DynamicSupervisor configuration:
  - [ ] distribution_strategy: Horde.UniformRandomDistribution
  - [ ] process_redistribution: :active
  - [ ] members: :auto
  - [ ] delta_crdt_options: [sync_interval: 100]
- [ ] Enhance ClusterManager node monitoring:
  - [ ] Implement proper nodedown handler
  - [ ] Trigger agent migration for failed nodes
- [ ] Agent state preservation:
  - [ ] Ensure agents implement :extract_state callback
  - [ ] Ensure agents implement :restore_state callback
  - [ ] Test state preservation during migration
- [ ] Test failover scenarios:
  - [ ] Graceful node shutdown
  - [ ] Ungraceful node failure (kill -9)
  - [ ] Network partition and recovery

### Phase 3: Phoenix.PubSub Integration

**Status**: 🔴 Not Started  
**Depends on**: Phase 2 completion

#### Tasks:
- [ ] Update HordeCoordinator broadcasting:
  - [ ] Replace local broadcasting with Phoenix.PubSub.broadcast/3
  - [ ] Subscribe to cluster topology changes
- [ ] Implement cluster-wide events:
  - [ ] Cluster formation events
  - [ ] Node join/leave events
  - [ ] Health check result distribution
  - [ ] Agent migration events
- [ ] Subscription management:
  - [ ] Auto-subscribe new nodes to relevant topics
  - [ ] Clean up subscriptions on node departure
- [ ] Test event distribution across cluster

### Phase 4: Testing and Verification

**Status**: 🔴 Not Started  
**Depends on**: Phase 3 completion

#### Tasks:
- [ ] Fix integration test issues:
  - [ ] Update ClusterCoordinator.perform_health_check calls
  - [ ] Fix any other test compatibility issues
- [ ] Multi-node test scenarios:
  - [ ] 3-node cluster formation
  - [ ] Agent distribution across nodes
  - [ ] Node failure triggers agent migration
  - [ ] Session lookup works after migration
  - [ ] Health monitoring works across cluster
- [ ] Verify all 5 postrequisites pass

### Phase 5: Architecture Cleanup

**Status**: 🔴 Not Started  
**Depends on**: Phase 4 completion

#### Tasks:
- [ ] Clarify component responsibilities:
  - [ ] Document ClusterManager scope (libcluster, node discovery)
  - [ ] Document HordeCoordinator scope (Horde management, PubSub)
- [ ] Remove overlapping functionality:
  - [ ] Consolidate health checking logic
  - [ ] Single source of truth for cluster state
- [ ] Session continuity verification:
  - [ ] Test sessions survive node failures
  - [ ] Verify Gateway can find migrated sessions
  - [ ] Ensure client connections maintained
- [ ] Update documentation with clear boundaries

## Success Criteria (5 Postrequisites)

- [ ] **Postrequisite 1**: Multi-node health tracking implementation
  - Status: ✅ Partially implemented in ClusterManager
  - Needs: Integration with distributed components
  
- [ ] **Postrequisite 2**: Distributed registry operations verified
  - Status: 🔴 Blocked by HordeRegistry local state issue
  - Needs: Phase 1 completion
  
- [ ] **Postrequisite 3**: Automatic agent failover working
  - Status: 🔴 Blocked by registry issue
  - Needs: Phase 1 & 2 completion
  
- [ ] **Postrequisite 4**: Cluster-wide event distribution via Phoenix.PubSub
  - Status: 🔴 Not implemented
  - Needs: Phase 3 completion
  
- [ ] **Postrequisite 5**: Session continuity across cluster changes
  - Status: 🔴 Not verified
  - Needs: All phases complete

## Current Blockers

1. **CRITICAL**: HordeRegistry stores state locally instead of using Horde.Registry
2. Integration tests have incorrect method calls
3. Unclear separation between ClusterManager and HordeCoordinator

## Next Actions

1. **IMMEDIATE**: Start Phase 1 - Fix HordeRegistry to use actual Horde.Registry
2. Only after Phase 1 is complete can we proceed with other phases
3. Each phase must be completed before starting the next due to dependencies

## Notes

- The original implementation attempted to work around Horde.Registry limitations but ended up creating a non-distributed solution
- Horde.Registry.register only registers the calling process, which is why the PID mapping workaround was attempted
- The correct approach is to have agents register themselves or use a via tuple pattern
- All distributed functionality depends on the registry being truly distributed

## Progress Tracking

Last Updated: [Current Date]

**Overall Progress**: 0/5 Phases Complete

- Phase 1: 0/10 tasks ⚠️ BLOCKING ALL PROGRESS
- Phase 2: 0/4 tasks
- Phase 3: 0/4 tasks  
- Phase 4: 0/5 tasks
- Phase 5: 0/4 tasks

**Total**: 0/27 tasks complete