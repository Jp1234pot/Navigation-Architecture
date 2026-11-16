Controller Integration Contract

Project: Navigation Architecture v2.2
Status: Proposed integration contract
Purpose: Define how the future Navigation Controller composes existing foundations.

1. Controller Responsibility

The Navigation Controller is the composition root of the architecture.

It is responsible for:

- Creating validated configuration.
- Constructing participating modules.
- Supplying declared dependencies.
- Coordinating module lifecycle.
- Connecting public callbacks.
- Managing optional capabilities.
- Handling initialization failures.
- Destroying owned modules safely.

The controller must not replace the internal responsibilities of individual foundations.

2. Ownership

The controller owns the module instances it constructs.

Each foundation retains ownership of its:

- Private state.
- Internal implementation.
- Internal connections.
- Public-method validation.
- Local cleanup behavior.

The controller must use public methods rather than accessing private fields.

Modules must not destroy other modules that they do not own.

3. Initialization Order

The proposed initialization sequence is:

1. Create validated configuration.
2. Create shared lifecycle and state services.
3. Create character and target-discovery services.
4. Create observation and estimation services.
5. Create pathfinding and waypoint services.
6. Create analysis and recovery services.
7. Create optional evidence and decision stores.
8. Create movement services.
9. Connect public callbacks.
10. Mark the controller Ready.

A module must not begin active work merely because it has been constructed.

4. Foundation K Integration

Foundation K consists of:

- ConfidenceLedger
- UncertaintyMap
- DecisionLedger

All three receive the validated configuration.

Their activation is controlled by:

"evidenceLedgerEnabled"

The default value is "false".

When disabled:

- ConfidenceLedger rejects recording and assessment.
- UncertaintyMap rejects observations and data retrieval.
- DecisionLedger rejects recording.

The controller may construct these modules while disabled, but must not interpret construction as activation.

The controller must not automatically:

- Record evidence.
- Observe uncertainty.
- Create decision records.
- Start sampling for Foundation K.
- Infer that stored observations represent complete world knowledge.

Calls to these methods must be explicit and supplied with valid caller-owned data.

5. Dependency Classification

Module| Dependency classification
Config| Required
StateManager| Required
LifecycleManager| Required
CharacterManager| Required for character-dependent capabilities
TargetDiscovery| Required for target discovery
PhysicsObserver| Required for observation-dependent analysis
VelocityEstimator| Required for velocity-dependent analysis
SamplingCoordinator| Optional until sampling is requested
PathfindingEngine| Optional until pathfinding is requested
WaypointTracker| Required for waypoint-progress tracking
MovementController| Optional and explicitly gated
AdaptiveRepath| Optional
RecoveryAnalysis| Optional
MultiThreatAnalysis| Optional
ConfidenceLedger| Optional
UncertaintyMap| Optional
DecisionLedger| Optional
TelemetryPanel| Optional

A missing optional module must not automatically stop unrelated capabilities.

6. Lifecycle States

The controller should expose these states:

- Uninitialized
- Initializing
- Ready
- Running
- Degraded
- Stopping
- Stopped
- Failed

"Ready" means initialization completed. It does not mean sampling, pathfinding, or movement has started.

"Running" means at least one explicitly requested operational capability is active.

"Degraded" means one or more capabilities are unavailable while other valid capabilities may continue.

7. Activation Boundaries

Construction and activation are separate operations.

The controller must distinguish:

- Module constructed.
- Module configured.
- Module ready.
- Capability activated.
- Capability stopped.

Movement must remain explicitly gated by configuration and a deliberate start request.

Evidence collection must remain explicitly gated by "evidenceLedgerEnabled" and explicit method calls.

No subsystem may infer permission to move from an analysis result alone.

8. Failure Isolation

Initialization should handle failures at the individual module boundary.

For each module:

1. Attempt construction.
2. Validate the returned instance.
3. Register cleanup ownership.
4. Record initialization status.
5. Continue only when the remaining dependency graph permits it.

A failed optional module should disable its dependent optional capability.

A failed required module should block only the capabilities that require it.

Failure reporting must not create an endless retry or reporting loop.

9. Shutdown Order

Shutdown should follow reverse dependency order.

The proposed sequence is:

1. Stop movement.
2. Stop sampling.
3. Cancel active path requests.
4. Disconnect controller callbacks.
5. Destroy analysis modules.
6. Destroy evidence and decision stores.
7. Destroy pathfinding and waypoint modules.
8. Destroy observation and estimation modules.
9. Destroy target and character services.
10. Destroy state and lifecycle services.

Each cleanup operation should be protected so one cleanup failure does not prevent unrelated cleanup operations.

10. Public Interface Rule

The controller must integrate against the actual committed public interfaces.

Documentation is not permission to invent methods or change existing signatures.

Before implementation, each constructor and method call must be checked against its source file.

Any intentional API change must be documented separately.

11. Verification Boundary

Static verification can establish:

- Module paths and imports.
- Constructor compatibility.
- Dependency wiring.
- Public method compatibility.
- Cleanup ownership.
- Configuration compatibility.
- Activation gates.

Runtime behavior still requires Roblox Studio testing.

The controller must not be described as runtime-verified until those tests have been performed.

12. Implementation Status

This contract is a proposed integration specification.

It does not claim that the Navigation Controller, shared registry, dependency manager, or full lifecycle orchestration already exists.
