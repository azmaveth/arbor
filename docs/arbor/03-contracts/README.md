# Section 03: Contracts

This section covers Arbor's contract specifications and schema-driven design approach.

## Documents in this Section

### [Core Contracts](./core-contracts.md)
Complete specification of Arbor's core data contracts:
- Message contracts and envelopes
- Agent contracts and behaviors
- Capability contracts and security
- Event contracts for system coordination

### [Schema-Driven Design](./schema-driven-design.md)
Comprehensive guide to Arbor's schema-driven approach:
- Technology stack (TypedStruct, Ecto, Norm)
- Layered contract strategy
- Implementation patterns
- Serialization strategies

### [Validation Strategy](./validation-strategy.md) *(Coming Soon)*
Detailed validation approaches for different boundaries:
- Boundary classification
- Validation techniques
- Error handling patterns
- Performance considerations

## Contract Categories

### Core Domain Contracts
- `Arbor.Contracts.Core.Message` - Inter-agent communication
- `Arbor.Contracts.Core.Agent` - Agent lifecycle and state
- `Arbor.Contracts.Core.Capability` - Security permissions
- `Arbor.Contracts.Core.Session` - User session management

### Event Contracts
- `Arbor.Contracts.Events.AgentEvent` - Agent lifecycle events
- `Arbor.Contracts.Events.SystemEvent` - System-wide events
- `Arbor.Contracts.Events.SecurityEvent` - Security audit events

### Integration Contracts
- MCP protocol messages
- LLM provider interfaces
- External API contracts

## Key Design Decisions

1. **TypedStruct for Internal Contracts**: Compile-time safety with zero dependencies
2. **Ecto for Boundary Validation**: Rich validation at system boundaries
3. **Native BEAM Terms Internally**: No serialization overhead within cluster
4. **Protocol Buffers for External APIs**: Efficient binary format for external communication

## Usage Examples

See the [Core Contracts](./core-contracts.md) document for detailed examples of:
- Creating and validating contracts
- Transforming between versions
- Serialization patterns
- Testing strategies

## Next Steps

After understanding contracts:
- [Components](../04-components/README.md) - See how components use contracts
- [Architecture](../05-architecture/README.md) - Understand contract flow
- [Implementation](../07-implementation/README.md) - Implement with contracts