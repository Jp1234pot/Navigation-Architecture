Navigation Architecture v2.2

Development Roadmap

Status: Planned
Last updated: 2026-11-16

This roadmap defines the intended development sequence for Navigation Architecture v2.2.

The goal is to integrate the existing foundations into one coherent architecture while preserving subsystem independence, clear interfaces, and failure isolation.

The phases below describe planned work. They do not indicate that implementation or testing has already been completed.

---

Phase 0: Preserve the Existing Baseline

Objective: Establish a reliable reference before integration changes begin.

- Preserve the current A-K and L1-L5 source packages.
- Record existing public APIs and configuration options.
- Identify incomplete, experimental, or undocumented components.
- Avoid rewriting working modules merely to fit a proposed structure.
- Keep the original source available for comparison.

Completion condition: Existing modules and their known contracts are inventoried.

Phase 1: Verify Interfaces and Dependencies

Objective: Determine how the existing modules actually connect.

- Verify constructor arguments and public methods.
- Identify required, optional, and enhancement dependencies.
- Map initialization and shutdown order.
- Identify duplicated responsibilities.
- Detect circular dependencies and hidden assumptions.
- Record API mismatches before integration.

Completion condition: A source-verified dependency graph exists.

Phase 2: Define the Shared Navigation Core

Objective: Establish the minimum common contract used by the architecture.

Proposed Core responsibilities:

- Module registration and identification.
- Dependency validation.
- Initialization and shutdown coordination.
- Module health reporting.
- Structured error reporting.
- Configuration and capability checks.
- Communication through defined public interfaces.

The Core should coordinate modules without owning their internal implementation.

Failure-isolation requirement:

- An optional module failure must not automatically disable unrelated modules.
- A required dependency failure should affect only the capabilities that depend on it.
- Core-service failures must be detectable and reported.
- Critical coordination failures should trigger a defined degraded or safe-stop state.
- Error reporting must not create recursive error loops.

Completion condition: The Core contract and its failure behavior are documented and agreed upon.

Phase 3: Integrate Existing Subsystems

Objective: Connect the existing foundations without unnecessarily replacing their internals.

Planned integration groups:

- Foundation A: architecture and lifecycle.
- Foundations B-D: target discovery, physical observation, and sampling.
- Foundation E: telemetry presentation.
- Foundations F-G: path computation and waypoint progress.
- Foundation H: explicit local movement.
- Foundations I-K: recovery, multi-contact analysis, and confidence support.
- Foundations L1-L5: arena analysis pipeline.

Integration should use public APIs and adapters where necessary.

Completion condition: Existing subsystems can register, initialize, report status, and shut down through the agreed architecture contracts.

Phase 4: Build the Interactive Interface

Objective: Provide a user-facing control layer.

Planned interface capabilities:

- PLAYER/NPC selection.
- ON/OFF controls.
- ESCAPE/PURSUE mode selection.
- Target information and status display.
- Current route and navigation information.
- Error and degraded-state notifications.
- Clear indication of whether movement is enabled.

The interface should communicate through public Core and subsystem interfaces rather than directly modifying private module state.

Completion condition: Interface controls can issue validated commands and display the resulting system state.

Phase 5: Add Behavior Coordination

Objective: Connect analysis, navigation, and movement into controlled behaviors.

Planned responsibilities:

- Target selection policy.
- Destination and route selection.
- Pursue behavior coordination.
- Escape behavior coordination.
- Route evaluation and replanning decisions.
- Movement handoff.
- Manual-input cooperation.
- Stop, cancellation, and recovery handling.

Behavior coordination must remain separate from low-level observation and movement implementation.

Movement must respect its explicit authorization and configuration gates.

Completion condition: Behavior commands follow a documented path from user input through validation, analysis, navigation, and any permitted movement action.

Phase 6: Integration and Failure-Isolation Testing

Objective: Verify that the architecture behaves correctly as a whole.

Test scenarios should include:

- Successful module registration.
- Missing required dependencies.
- Missing optional dependencies.
- Module initialization failure.
- Runtime module errors.
- Core-service degradation.
- GUI failure.
- Analysis subsystem failure.
- Movement rejection and safe stopping.
- Recovery after a module becomes available again.
- Repeated initialization and shutdown.
- Manual-input interaction.

Completion condition: Failure scenarios produce predictable, documented behavior without unnecessary system-wide failure.

Phase 7: Stabilization and Verification

Objective: Establish a reliable release candidate.

- Complete static checks.
- Run module-level tests.
- Run integration tests.
- Run regression tests.
- Record unresolved defects.
- Verify configuration defaults.
- Confirm movement remains explicitly gated.
- Update documentation to match the actual implementation.
- Assign verification levels to each subsystem.

Completion condition: The architecture has documented evidence for its verified capabilities and known limitations.

---

Development Priorities

The recommended order is:

1. Preserve and inspect existing source.
2. Verify interfaces and dependencies.
3. Agree on the minimum Core contract.
4. Integrate existing modules.
5. Build the interactive interface.
6. Add behavior coordination.
7. Test failure isolation and stabilize.

Autonomous behavior should not be treated as complete before the underlying interfaces, movement authorization, manual-input cooperation, and failure handling are defined.

---

Guiding Principle

One Integrated Architecture. Independent Subsystems. Isolated Failure.

The Core provides coordination, not unrestricted control over every module.

Subsystems retain clear responsibilities and communicate through defined contracts.

A failure should remain limited to the smallest affected capability whenever safe operation permits it.
