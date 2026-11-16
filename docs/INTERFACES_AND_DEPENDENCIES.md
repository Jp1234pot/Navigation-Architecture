Interfaces and Dependencies

Project: Navigation Architecture v2.2
Document status: Interface and integration specification

1. Purpose

This document defines the intended rules for communication, dependency management, ownership, and failure isolation across Navigation Architecture.

The objective is to allow independent subsystems to contribute to one integrated architecture without requiring direct access to one another's internal implementations.

This document distinguishes existing interfaces from proposed Navigation Core contracts.

2. Existing Public Interfaces

Existing interfaces must be preserved unless an intentional change is approved.

The following are known interfaces from the documented packages.

2.1 Foundation B

"FactionValidator"

- "new(config)"
- "GetPlayerFaction(player)"
- "GetModelFaction(model)"
- "Classify(candidate)"
- "IsEligible(candidate)"

"TargetDiscovery"

- "new(localPlayer, config, factionValidator)"
- "GetCandidates()"
- "FindNearest(origin, candidates?)"
- "IsCandidateCurrent(candidate)"

2.2 Foundation C

"PhysicsObserver"

- "new(config?)"
- "Observe(model)"
- "Destroy()"

"VelocityEstimator"

- "new(config?)"
- "Update(snapshot)"
- "GetEstimate()"
- "Reset()"
- "Destroy()"

2.3 Foundation D

"SamplingCoordinator"

- "new(dependencies)"
- "SetOnSample(callbackOrNil)"
- "SetTarget(candidate, targetMode?)"
- "ClearTarget(reason?)"
- "Start()"
- "Stop()"
- "GetLatest()"
- "Destroy()"

2.4 Foundation H

"MovementController"

- "new(config, characterManager)"
- "SetOnStatus(callbackOrNil)"
- "GetStatus()"
- "Start(character, pathPacket)"
- "Stop(reason?)"
- "Destroy()"

2.5 Foundation L1-L5

"ArenaAnalysisPipeline"

- "new(worldRoot, overrides?)"
- "Observe(origin, characterToExclude?, stores?)"
- "Compare(startSurfaceId, goalSurfaceId, movementEnvelope?, stores?)"
- "GetLatest()"
- "GetCounts()"
- "Destroy()"

These are existing documented interfaces, not a proposed replacement API.

Other foundations should retain their original source-defined contracts.

3. Ownership Rules

Each module owns its:

- Internal state.
- Private implementation.
- Internal resources.
- Cleanup responsibilities.
- Local validation.

Other modules must not directly manipulate private fields or internal implementation details.

Communication should happen through public methods, callbacks, events, or explicitly defined data contracts.

4. Dependency Classification

Every dependency should be assigned a clear classification.

Required

The dependent capability cannot safely operate without it.

If unavailable, that capability should become blocked or degraded.

Optional

The subsystem can continue operating without it.

The optional feature should be disabled without unnecessarily stopping the subsystem.

Enhancement

The dependency improves performance, analysis, or presentation but is not essential to basic operation.

Its failure should reduce capability rather than automatically stop the subsystem.

5. Proposed Module Registration Contract

The future Navigation Core should maintain a registry of participating modules.

A proposed registration record:

Field| Purpose
moduleId| Unique module identifier
version| Module implementation version
apiVersion| Public interface version
dependencies| Required and optional dependencies
capabilities| Features exposed by the module
lifecycle| Current lifecycle state
health| Current operational health
errorHandler| Optional reporting interface

This is a proposed metadata structure, not an existing API.

The registry should reject duplicate identifiers and incompatible required interfaces.

6. Proposed Lifecycle Contract

A module should follow a predictable lifecycle:

1. Registered
2. Dependency validation
3. Initializing
4. Ready
5. Running
6. Degraded
7. Stopping
8. Stopped

A module may enter an error state during initialization or operation.

Recovery should be explicit and should not assume that restarting a failed module is always safe.

7. Proposed Health Model

The Core should distinguish at least these health states:

State| Meaning
Healthy| Required operations are functioning
Degraded| Some capabilities are unavailable
Blocked| A required dependency prevents operation
Initializing| Module is being prepared
Stopped| Module is not operating
Failed| Module encountered an unrecovered failure

Health reporting should describe actual capability availability, not merely whether a module exists.

8. Proposed Structured Error Contract

Errors should use a consistent record.

Proposed fields:

Field| Purpose
sourceModule| Module reporting the error
operation| Operation during which it occurred
errorCode| Stable machine-readable identifier
severity| Informational, warning, error, or critical
timestamp| Time of occurrence
correlationId| Optional identifier linking related operations
message| Human-readable explanation
affectedCapability| Capability impacted by the error

The record should avoid exposing private implementation details unnecessarily.

9. Error Reporting and Failure Isolation

The error-reporting process must not become a new source of cascading failures.

Proposed behavior:

1. A subsystem detects an error.
2. The subsystem safely attempts to report it.
3. The Core records the report if available.
4. Health information is updated.
5. Only affected dependent capabilities are degraded.
6. Unrelated subsystems continue operating where their dependencies permit.

Core Reporting Failure

If the Core's error-reporting service is unavailable:

- A subsystem must not enter an endless reporting loop.
- It should use a bounded local fallback where appropriate.
- The original operational error must not be silently treated as success.
- Recovery or retry behavior must be controlled.

A reporting failure should not automatically disable unrelated subsystem functionality.

10. Dependency Failure Rules

Failure| Expected response
Optional dependency unavailable| Disable optional capability
Enhancement dependency unavailable| Continue with reduced capability
Required dependency unavailable| Block or degrade dependent capability
GUI unavailable| Analysis and other independent services continue
Analysis module unavailable| Unrelated movement and observation remain available where safe
Error reporting unavailable| Use bounded fallback if available
Core partially unavailable| Continue only capabilities whose required contracts remain valid

The Core must distinguish a genuinely required service from a convenience service.

11. Communication Rules

Subsystem communication should follow these principles:

- Prefer stable public interfaces.
- Validate received data.
- Avoid circular dependencies.
- Avoid unrestricted direct access to another module's state.
- Keep messages bounded.
- Define ownership of transmitted data.
- Define whether callbacks are synchronous or asynchronous.
- Avoid assuming that a receiving module is always available.

Cross-subsystem communication should not silently create new dependencies.

12. Version Compatibility

The Core should validate public API compatibility.

A module implementation version and its public API version should be treated as separate values.

An implementation update does not necessarily require a public API change.

Breaking interface changes should be documented and approved before integration.

13. Proposed Core Service Boundaries

The following are candidate responsibilities:

- ModuleRegistry
- DependencyManager
- LifecycleManager
- HealthManager
- ErrorManager
- CommunicationService
- CoreConfig

These names describe proposed organizational responsibilities. They do not establish that these modules already exist.

The final design should consolidate responsibilities where doing so reduces unnecessary complexity.

14. Integration Rules

Before a subsystem is integrated into the shared Core:

1. Inspect its original source.
2. Record its public interface.
3. Identify its owned resources.
4. Map required and optional dependencies.
5. Identify possible failure conditions.
6. Define its lifecycle behavior.
7. Define its health reporting.
8. Verify compatibility.
9. Test failure isolation.

Integration must not silently replace existing subsystem behavior.

15. Open Decisions

The following decisions remain unresolved:

- Exact registration schema.
- Minimum mandatory Core services.
- Error-code naming conventions.
- Health update mechanism.
- Local fallback reporting format.
- Recovery and restart policy.
- Callback and event communication rules.
- API compatibility policy.
- Core shutdown behavior when subsystems are still active.

These decisions should be finalized before implementing the shared Core.
