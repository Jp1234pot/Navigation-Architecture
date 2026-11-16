Navigation Architecture v2.2

Architecture Decision Log

Status: Living document
Last updated: 2026-11-16

This document records important architectural decisions, their reasoning, and unresolved questions.

Decisions may be revised when source inspection, implementation, or testing provides new evidence.

---

D-001: One Integrated Architecture

Decision: The foundations and subsystems are intended to contribute to one larger Navigation Architecture.

Reasoning:

- Shared coordination avoids disconnected components.
- Common contracts make integration more predictable.
- Subsystems can retain their individual responsibilities while contributing to the overall architecture.

Consequence: A shared Navigation Core is planned as the integration layer.

Status: Accepted direction; Core implementation is not yet established.

D-002: Subsystem Independence and Failure Isolation

Decision: Subsystems should operate independently wherever their dependencies permit.

Reasoning:

- A failure in one subsystem should not automatically disable unrelated capabilities.
- Modules should expose their health and errors through defined interfaces.
- Required dependencies must be distinguished from optional dependencies.

Consequence: Dependency validation, degraded states, and isolated error handling are architectural requirements.

Status: Accepted direction; implementation details remain to be designed.

D-003: Observation Restrictions Do Not Define the Entire Architecture

Decision: Read-only restrictions apply to the observation responsibilities of relevant modules, not automatically to every subsystem.

Reasoning:

- Observation and telemetry should not unnecessarily modify the environment being observed.
- Interface state, internal state, navigation calculations, and coordination are separate responsibilities.
- The broader architecture includes planned interactive controls and controlled local movement.

Consequence: Each subsystem must document what it may observe, calculate, display, and modify.

Status: Accepted.

D-004: Movement Must Be Explicitly Gated

Decision: Local movement remains a separately owned capability with explicit authorization and configuration requirements.

Reasoning:

- Path computation and movement execution are different operations.
- A calculated route does not automatically authorize movement.
- Movement should have clear start, stop, rejection, and failure behavior.

Consequence: Movement remains disabled by default and requires explicit invocation under its documented conditions.

Status: Existing Foundation H contract; broader behavior integration remains planned.

D-005: Analysis Results Are Not Guarantees

Decision: Geometry, reachability, confidence, route, and movement-feasibility results must be presented as analytical estimates.

Reasoning:

- Observations may be incomplete or outdated.
- Candidate connections do not prove actual reachability.
- Configured movement limits do not guarantee runtime success.

Consequence: Consumers must account for uncertainty rather than treating analysis output as authoritative physical truth.

Status: Accepted.

D-006: Preserve Existing Contracts During Consolidation

Decision: Integration should preserve existing subsystem behavior and public contracts wherever practical.

Reasoning:

- Rewriting modules during integration increases unnecessary risk.
- Existing implementations provide a baseline for comparison.
- Adapters can resolve interface differences without forcing every module into the same internal design.

Consequence: Source inspection and dependency verification precede major refactoring.

Status: Accepted direction.

D-007: Documentation Must Distinguish Existing and Proposed Components

Decision: Documentation must clearly identify implemented, source-reviewed, proposed, and verified components.

Reasoning:

- An architectural proposal is not proof of implementation.
- Source inspection is not runtime verification.
- Testing claims must be supported by actual evidence.

Consequence: Project status and testing records must be updated as work progresses.

Status: Accepted.

---

Open Architecture Questions

The following questions require further design decisions:

1. What is the minimum set of services that the Navigation Core must provide?
2. What registration metadata and version-compatibility rules should modules use?
3. Should module health be event-driven, queried on demand, or support both?
4. What structured error categories and severity levels are necessary?
5. What fallback behavior should remain available when Core services fail?
6. How should manual input cooperate with Pursue and Escape behaviors?
7. Which subsystem owns target selection, and which owns behavior decisions?
8. How should GUI state remain synchronized with actual subsystem state?
9. Should the existing A-K and L1-L5 groups remain separate packages or be consolidated into larger installation units?

These questions should be resolved using the existing source contracts and integration requirements, not assumptions.

---

Change Policy

When a decision changes:

- Preserve its original identifier.
- Record the revised decision and date.
- Explain why the previous decision changed.
- Identify affected modules and documentation.
- Update implementation plans where necessary.

This log records architectural reasoning. It does not override the actual source code or establish capabilities that have not been implemented.
