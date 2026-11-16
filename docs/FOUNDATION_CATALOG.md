Foundation Catalog: A-K

Project: Navigation Architecture v2.2
Document status: Source-based catalog

This document records the known responsibilities and boundaries of Foundations A-K.

The catalog distinguishes existing component responsibilities from future integration proposals.

Foundation A: Base Architecture

Role: Establishes the foundational client architecture and shared infrastructure.

Its documented architectural responsibilities include:

- Configuration management.
- Shared state management.
- Character access.
- Lifecycle and cleanup management.
- Module construction and coordination.

Boundary: Foundation A provides infrastructure. It should not absorb the private implementation responsibilities of every other foundation.

Exact public APIs should be taken from the original Foundation A source package.

Foundation B: Faction Validation and Target Discovery

Role: Determines whether discovered player or NPC candidates satisfy configured eligibility rules.

Components

- "FactionValidator"
- "TargetDiscovery"

Known interfaces

"FactionValidator":

- "new(config)"
- "GetPlayerFaction(player)"
- "GetModelFaction(model)"
- "Classify(candidate)"
- "IsEligible(candidate)"

"TargetDiscovery":

- "new(localPlayer, config, factionValidator)"
- "GetCandidates()"
- "FindNearest(origin, candidates?)"
- "IsCandidateCurrent(candidate)"

Boundaries

- Excludes the local player from player candidates.
- Uses the configured NPC folder and its direct Model children.
- Does not use an unrestricted Workspace descendant search as a fallback.
- Candidate records must be revalidated before use.

Discovery does not itself authorize movement or establish target intent.

Foundation C: Physical Observation

Role: Provides bounded, read-only observations of physical character state.

Components

- "PhysicsObserver"
- "VelocityEstimator"

Known interfaces

"PhysicsObserver":

- "new(config?)"
- "Observe(model)"
- "Destroy()"

"VelocityEstimator":

- "new(config?)"
- "Update(snapshot)"
- "GetEstimate()"
- "Reset()"
- "Destroy()"

Responsibilities

- Observe character and physics-related properties.
- Produce structured snapshots.
- Estimate velocity from successive position observations.
- Maintain bounded estimation state.

Boundaries

- Does not directly control observed characters.
- Position-derived velocity is an estimate, not an authoritative physics measurement.
- Observations may become stale or unavailable.

Foundation D: Controlled Telemetry Sampling

Role: Coordinates periodic observations without uncontrolled polling.

Component

"SamplingCoordinator"

Known interfaces

- "new(dependencies)"
- "SetOnSample(callbackOrNil)"
- "SetTarget(candidate, targetMode?)"
- "ClearTarget(reason?)"
- "Start()"
- "Stop()"
- "GetLatest()"
- "Destroy()"

Responsibilities

- Samples the local character and explicitly selected target.
- Uses one owned Heartbeat connection.
- Enforces a configured sampling interval.
- Revalidates the selected target.
- Resets estimation history when necessary.

Known constraints

- Default sampling interval: 0.25 seconds.
- Configured interval range: 0.05-2.0 seconds.
- At most one sample per Heartbeat.
- No catch-up bursts.
- No automatic target selection.
- No persistent learning.

D controls sampling. It does not own target-selection policy or movement behavior.

Foundation E: Telemetry Presentation

Role: Presents relevant telemetry through a local GUI.

Responsibilities

- Display selected telemetry information.
- Present observation and status information.
- Maintain its own presentation lifecycle.

Boundaries

- The documented telemetry panel is read-only.
- It does not independently authorize movement.
- It should not own target-discovery or pathfinding logic.

Future interactive controls may be added through a separately designed interface layer.

Foundation F: Path Computation

Role: Computes a path between explicitly supplied endpoints.

Responsibilities

- Accept explicit start and destination positions.
- Request path computation.
- Return a bounded path result or failure information.

Boundaries

- Does not independently select targets.
- Does not independently choose destinations.
- Does not execute movement.
- Does not imply that a computed path is guaranteed to succeed.

Foundation G: Waypoint Progress Tracking

Role: Tracks progress through a computed waypoint sequence.

Responsibilities

- Maintain waypoint progression information.
- Identify current and subsequent waypoint state.
- Report progress and relevant tracking status.

Boundaries

- Tracking is distinct from movement execution.
- A waypoint record does not prove that the character physically reached its intended destination.
- Automatic route selection is not implied.

Exact public methods should remain aligned with the original source package.

Foundation H: Explicit Local Movement

Role: Executes an explicitly supplied local movement route.

Component

"MovementController"

Known interfaces

- "new(config, characterManager)"
- "SetOnStatus(callbackOrNil)"
- "GetStatus()"
- "Start(character, pathPacket)"
- "Stop(reason?)"
- "Destroy()"

Responsibilities

- Validate the current local character.
- Validate the supplied path packet.
- Execute supported Walk and Jump waypoint actions.
- Track movement completion.
- Apply finite segment timeouts.
- Report movement status.

Activation requirements

Movement requires all of the following:

1. "enabled" is true.
2. "pathfindingEnabled" is true.
3. "movementEnabled" is true.
4. An explicit "Start(character, pathPacket)" call is made.
5. The supplied character and path packet pass validation.

Movement is disabled by default.

Boundaries

The documented implementation uses local Humanoid movement interfaces such as "Humanoid:MoveTo" and Jump.

It does not directly set CFrame, Position, velocity, WalkSpeed, or character attributes.

It does not provide automatic Pursue/Escape behavior or unrestricted automatic replanning.

Foundation I: Recovery and Repath Analysis

Role: Evaluates recovery conditions and whether another path request may be appropriate.

Responsibilities

- Maintain bounded recovery diagnostics.
- Evaluate explicit repath considerations.
- Apply cooldown and request-budget constraints.
- Support backoff and circuit-breaker behavior.

Boundaries

- Eligibility analysis is not itself a path request.
- A diagnostic record does not prove why a movement failure occurred.
- Automatic movement recovery must follow an explicitly defined policy.

Foundation J: Multi-Contact Analysis

Role: Evaluates multiple nearby contacts and their observed proximity or closing trajectories.

Responsibilities

- Analyze bounded sets of player and NPC observations.
- Compare relative positions and estimated movement.
- Produce structured proximity and trajectory information.

Boundaries

- Proximity does not establish hostile intent.
- A closing trajectory does not prove an attack.
- Analysis does not automatically authorize movement or behavior decisions.

Foundation K: Confidence and Decision Records

Role: Maintains bounded, session-only records supporting uncertainty-aware analysis.

Components

- "ConfidenceLedger"
- "UncertaintyMap"
- "DecisionLedger"

Responsibilities

- Record confidence-related information.
- Track uncertainty.
- Preserve bounded decision records.
- Support analysis without treating estimates as certainty.

Boundaries

- Records are session-only.
- Confidence is not automatically a calibrated probability.
- Decision records are not proof that a decision was correct.
- Stored evidence should not be treated as authoritative physical truth.

Cross-Foundation Rules

Ownership

Each foundation owns its internal state and implementation details.

Other foundations should interact through documented public interfaces.

Dependencies

Dependencies must be explicitly declared and validated.

A failure should affect only the dependent functionality wherever possible.

Lifecycle

Initialization, operation, shutdown, and cleanup should be predictable.

Error Handling

Errors should be reported without creating recursive error loops or silently hiding failures.

Consolidation

Foundations may later be grouped into larger installable subsystems.

Consolidation must preserve existing contracts unless an intentional API change is approved.

Verification Notice

This catalog records documented responsibilities and known interfaces.

It does not claim that every foundation has passed Roblox Studio runtime testing or Luau static verification.

When original source and this catalog disagree, the original source must be inspected and the documentation corrected.
