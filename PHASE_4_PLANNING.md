# Phase 4 Planning - Mox Migration Continuation

## Overview

Following the successful completion of Phase 3b, this document outlines the plan for Phase 4 of the Mox migration project.

## Phase 3b Recap

### Achievements
- Migrated 2 of 194 mocks (1% by count, but highest complexity)
- Eliminated 948 lines of code
- Established Mox infrastructure and patterns
- Created comprehensive documentation

### Foundation Established
- Contract-based testing patterns
- Helper functions in MoxSetup
- Direct module injection support
- Migration cookbook with examples

## Phase 4 Objectives

### Primary Goals
1. **Migrate LocalRegistry Mock**
   - Estimated 300+ lines of code
   - Central to many tests
   - High impact on test reliability

2. **CI/CD Optimization**
   - Configure test runs to use `@tag :slow`
   - Separate unit and integration test runs
   - Measure performance improvements

3. **Team Knowledge Transfer**
   - Document patterns in team wiki
   - Conduct pairing sessions
   - Create video walkthrough

### Secondary Goals
1. **Automate Simple Migrations**
   - Create script for basic mock conversions
   - Generate behaviours from existing mocks
   - Automate helper function creation

2. **Metrics Collection**
   - Test execution time benchmarks
   - Code coverage analysis
   - Flakiness tracking

## Technical Targets

### LocalRegistry Migration
```elixir
# Current: apps/arbor_core/lib/arbor/test/mocks/local_registry.ex
# Target: Replace with Mox-based RegistryMock

# Steps:
1. Create LocalRegistryBehaviour
2. Add to MoxSetup
3. Migrate test files using LocalRegistry
4. Delete LocalRegistry mock
```

### Expected Impact
- Code reduction: ~300 lines
- Tests affected: ~15-20 files
- Performance: Faster test execution
- Reliability: No timing dependencies

## Implementation Plan

### Week 1: Analysis & Planning
- [ ] Analyze LocalRegistry usage patterns
- [ ] Identify all dependent test files
- [ ] Create migration checklist
- [ ] Set up performance baselines

### Week 2: Implementation
- [ ] Create LocalRegistryBehaviour
- [ ] Implement Mox setup helpers
- [ ] Migrate first batch of tests
- [ ] Validate test coverage

### Week 3: Completion & Optimization
- [ ] Complete remaining test migrations
- [ ] Delete LocalRegistry mock
- [ ] Optimize CI configuration
- [ ] Document lessons learned

### Week 4: Knowledge Transfer
- [ ] Update team documentation
- [ ] Conduct training sessions
- [ ] Plan Phase 5

## Success Criteria

1. **Technical**
   - LocalRegistry completely removed
   - All dependent tests passing
   - No increase in test flakiness
   - Measurable performance improvement

2. **Process**
   - CI optimized for test categories
   - Team trained on Mox patterns
   - Automation tools created

3. **Documentation**
   - Migration patterns updated
   - Metrics documented
   - Phase 5 plan created

## Risk Mitigation

### Identified Risks
1. **Complex Dependencies**: LocalRegistry may have hidden dependencies
   - Mitigation: Thorough analysis before migration

2. **Test Coverage Gaps**: Some tests may lose coverage during migration
   - Mitigation: Run coverage reports before/after

3. **Team Resistance**: Developers may prefer familiar mocks
   - Mitigation: Show performance/reliability benefits

## Resource Requirements

- **Developer Time**: 2 developers, 50% allocation
- **Review Time**: Senior developer reviews
- **CI Resources**: Additional test runs during migration

## Next Steps

1. Review and approve this plan
2. Create Phase 4 project board
3. Schedule kick-off meeting
4. Begin LocalRegistry analysis

---

*Phase 4 Target Start: Next Sprint*  
*Estimated Duration: 4 weeks*  
*Success Metric: 3% total mock migration (6 of 194)*