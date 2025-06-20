# Section 05: Architecture

This section explores Arbor's architectural patterns and design decisions.

## Documents in this Section

### [Agent Architecture](./agent-architecture.md) *(To be created)*
Comprehensive guide to Arbor's agent model:
- Two-tiered agent taxonomy (Coordinator vs Worker)
- Agent lifecycle and state management
- Supervision strategies
- Agent communication patterns

### [Communication Patterns](./communication-patterns.md)
High-performance communication strategies:
- Native BEAM communication for same-cluster agents
- Protocol fallbacks for external clients
- Message routing and transport abstraction
- Performance optimization techniques

### [Command Architecture](./command-architecture.md) *(To be created)*
Asynchronous command processing patterns:
- Command/Event separation
- Execution tracking
- Progress notifications
- Error handling strategies

### [Integration Patterns](./integration-patterns.md) *(To be created)*
Patterns for integrating with external systems:
- CLI and Web client integration
- MCP server integration
- LLM provider abstraction
- External API patterns

## Key Architectural Patterns

### 1. Gateway Pattern
All client interactions flow through a unified gateway that provides:
- Authentication and authorization
- Capability discovery
- Async operation management
- Event routing

### 2. Agent Hierarchy
Two-tiered agent model for clear separation of concerns:
- **Coordinator Agents**: Long-lived, manage workflows
- **Worker Agents**: Ephemeral, perform specific tasks

### 3. Event-Driven Architecture
Asynchronous, event-driven design enables:
- Non-blocking operations
- Real-time progress updates
- Multi-client support
- Fault isolation

### 4. Capability Delegation
Security through capability delegation:
- Agents start with zero permissions
- Explicit capability grants
- Automatic revocation on termination
- Constraint propagation

## Architecture Decisions

### Why Distributed by Default?
- Horizontal scalability
- Fault tolerance
- Zero-downtime deployments
- Geographic distribution

### Why Event Sourcing?
- Complete audit trail
- Time-travel debugging
- State reconstruction
- Multiple read models

### Why Contracts-First?
- Clear boundaries
- Independent development
- Multiple implementations
- Better testing

## Performance Considerations

- **Native BEAM Communication**: ~15μs latency for same-node
- **Cross-Node Communication**: ~100μs-1ms latency
- **External Protocol**: ~1-5ms+ latency
- **Message Batching**: Reduce overhead for bulk operations

## Next Steps

- [Infrastructure](../06-infrastructure/README.md) - Deploy the architecture
- [Components](../04-components/README.md) - Understand building blocks
- [Implementation](../07-implementation/README.md) - Build with patterns