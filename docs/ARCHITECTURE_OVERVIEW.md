Architecture Overview

Project: Navigation Architecture
Version: 2.2
Document status: Architecture documentation

1. Architectural Objective

Navigation Architecture is intended to operate as one integrated architecture composed of independently owned subsystems.

The central design objective is:

Unified Architecture. Independent Operation. Isolated Failure.

The architecture should support shared coordination without forcing every subsystem to depend on every other subsystem.

The Navigation Core is intended to provide common contracts and coordination services. Subsystems retain responsibility for their own internal operations.

2. Current Architectural Structure

There are two documented composition structures.

2.1 NavigationController

The current NavigationController composes the navigation-related Foundations A-K.

Its responsibilities include constructing modules, supplying shared dependencies, and coordinating the current navigation components.

It is the existing navigation bootstrap, not yet the finalized shared Navigation Core.

2.2 ArenaAnalysisPipeline

ArenaAnalysisPipeline composes the separate Arena Analysis foundations L1-L5.

It provides a bounded analysis workflow for environmental geometry, candidate connections, uncertainty, route comparison, and movement feasibility.

It remains independently owned rather than being treated as an internal part of NavigationController.

3. Subsystem Classification

Group| Components| Responsibility
Core Infrastructure| A| Base architecture and shared infrastructure
Target Discovery| B| Faction validation and candidate discovery
Physical Observation| C| Physics snapshots and velocity estimation
Sampling| D| Controlled telemetry sampling
Presentation| E| Telemetry display
Navigation| F, G| Path computation and waypoint tracking
Movement| H| Explicit local movement
Recovery| I| Recovery diagnostics and repath eligibility
Threat Analysis| J| Multi-contact analysis
Evidence and Confidence| K| Confidence, uncertainty, and decision records
Arena Analysis| L1-L5| Environmental and hypothetical route analysis

This classification is organizational. It does not automatically establish new runtime dependencies or merge existing implementations.

4. Intended Navigation Core

The future Navigation Core should provide a stable shared foundation.

Proposed responsibilities:

- Module registration.
- Dependency validation.
- Lifecycle coordination.
- Health monitoring.
- Structured error reporting.
- Shared configuration contracts.
- Controlled subsystem communication.
- Version and compatibility checks.

The Core should coordinate public interfaces rather than accessing private subsystem internals.

4.1 Core Independence

Subsystems should not require every optional Core service to function.

For example:

- A subsystem may operate without the GUI.
- A presentation failure should not stop observation.
- A diagnostic failure should not stop unrelated navigation calculations.
- A required dependency failure should disable or degrade only the features that require it.

Some minimal contracts may be mandatory for registration or lifecycle management. The exact boundary remains to be specified.

5. Subsystem Independence

Each subsystem should:

1. Own its internal state.
2. Expose a documented public interface.
3. Declare its dependencies.
4. Validate incoming data.
5. Report operational failures.
6. Support controlled initialization and shutdown.
7. Avoid modifying another subsystem's private state.

Independent operation does not mean ignoring dependencies. It means dependency failures should have limited and predictable effects.

6. Failure Isolation Model

The intended failure model distinguishes three dependency conditions.

Required Dependency

A feature cannot safely operate without this dependency.

If unavailable, only the dependent feature should enter a blocked or degraded state.

Optional Dependency

The feature can operate without this dependency.

Its absence should disable only the optional enhancement.

Enhancement Dependency

The dependency improves capability but is not necessary for the basic operation.

The subsystem should retain its basic functionality when possible.

Failure Flow

A subsystem detects an error and reports it through its available reporting interface.

The Core records the error, updates health information, and determines whether dependent capabilities need to degrade.

Error reporting itself must not create an endless recursive failure loop.

7. Current A-K Relationship

The current navigation modules form a broad sequence:

- A provides the base architecture.
- B discovers and validates candidates.
- C observes physical state.
- D samples observations.
- E presents telemetry.
- F computes paths.
- G tracks waypoint progress.
- H performs explicitly requested local movement.
- I evaluates recovery and repath eligibility.
- J analyzes multiple nearby contacts.
- K stores bounded confidence, uncertainty, and decision information.

This is a conceptual relationship map. Actual dependencies must follow the source package contracts.

8. Arena Analysis Relationship

L1-L5 form a separate analysis pipeline:

1. L1 observes environmental geometry.
2. L2 evaluates candidate surface connections.
3. L3 evaluates confidence and uncertainty.
4. L4 compares hypothetical routes.
5. L5 evaluates routes against a supplied movement envelope.

The pipeline can provide analysis results to other components through an agreed public interface.

Its outputs should not automatically authorize movement.

9. Future Interface and Behavior Layer

The broader intended architecture includes an interactive layer.

Its planned responsibilities include:

- PLAYER/NPC selection.
- ON/OFF controls.
- ESCAPE/PURSUE selection.
- Target and destination selection.
- Route request and comparison.
- Movement authorization.
- Manual-input cooperation.
- Status and error presentation.

The interface should issue commands through public contracts rather than directly modifying private subsystem state.

Behavior decisions, route analysis, and movement execution should remain distinguishable responsibilities.

10. Dependency Direction

The intended dependency direction is:

Interface → Public Core Contracts → Subsystem Interfaces → Owned Implementations

Subsystems may communicate through documented interfaces or Core-mediated messages.

Circular dependencies should be avoided.

The Core should not need to understand the private implementation of every subsystem.

11. Architectural Constraints

- Preserve existing public APIs during consolidation unless a change is deliberately approved.
- Do not confuse observation with the entire architecture's operating scope.
- Do not treat hypothetical analysis as guaranteed physical behavior.
- Do not silently turn explicit operations into automatic behavior.
- Keep movement authorization separate from route computation.
- Keep subsystem failures isolated wherever dependency requirements allow.
- Record significant interface and dependency changes.

12. Open Design Questions

The following require formal decisions before implementation:

1. What is the minimum mandatory Navigation Core contract?
2. Which services should remain optional?
3. What module registration metadata is required?
4. How should health states be represented?
5. What structured error format should be standardized?
6. How should subsystems operate when Core reporting is unavailable?
7. How should manual input cooperate with local movement?
8. How should PLAYER/NPC selection interact with Pursue/Escape behavior?
9. Should Arena Analysis register directly with Core or through an adapter?

These questions should be resolved before the Core implementation is considered finalized.
