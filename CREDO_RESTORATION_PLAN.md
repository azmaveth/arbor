# Credo Restoration Plan

## Current Status

After Mox migration Phase 3b, we have:
- **146 code readability issues** (mostly minor: module ordering, parentheses, whitespace)
- **195 software design suggestions** (mostly duplicate code between mocks and production)

## Categories of Issues

### 1. Duplicate Code (173 issues)
**Primary Source**: LocalCoordinator mock duplicates HordeCoordinator logic
- These will be eliminated when LocalCoordinator is replaced with Mox in future phases
- **Action**: Defer until Phase 4+ when LocalCoordinator is migrated

### 2. Module Ordering (30+ issues)
**Issue**: `alias` statements not in alphabetical order or before other directives
- Quick fixes that improve code consistency
- **Action**: Fix in a dedicated cleanup commit

### 3. Function Definition Style (15+ issues)
**Issue**: Parentheses on zero-argument functions
- Style inconsistency: `def foo()` should be `def foo`
- **Action**: Quick fix with automated formatting

### 4. Test File Issues (50+ issues)
**Issue**: Various readability issues in test files
- Module ordering, implicit try blocks, complex functions
- **Action**: Fix during next test file modifications

## Restoration Strategy

### Phase 1: Quick Wins (Immediate)
1. Fix module ordering issues in production code
2. Remove parentheses from zero-argument functions
3. Fix trailing whitespace

### Phase 2: Test File Cleanup (Next Sprint)
1. Fix module ordering in test files
2. Simplify complex test functions
3. Address implicit try blocks

### Phase 3: Design Issues (Future Phases)
1. Eliminate duplicate code through Mox migration
2. Complete removal of hand-written mocks
3. Achieve full Credo compliance

## Temporary Configuration

Currently using `.credo.temporary.exs` which:
- Disables custom architectural checks during migration
- Allows some duplication during transition period
- Should be removed once migration is complete

## Target Metrics

- **Short Term**: Reduce readability issues to <50
- **Medium Term**: Eliminate all duplicate code through Mox migration
- **Long Term**: Achieve 0 Credo issues with strict mode

## Next Steps

1. Keep temporary Credo config until Phase 4
2. Fix quick wins in production code
3. Plan test file cleanup for next sprint
4. Track progress in future phases