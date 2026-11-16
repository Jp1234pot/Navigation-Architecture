Arena Analysis: L1-L5

Project: Navigation Architecture v2.2
Subsystem: Arena Analysis
Document status: Source-based subsystem documentation

1. Overview

Arena Analysis is a separate, modular analysis subsystem composed of five foundations:

- L1: Arena Geometry Observation
- L2: Reachability Analysis
- L3: Spatial Confidence and Uncertainty
- L4: Hypothetical Route Comparison
- L5: Movement Feasibility Analysis

The foundations form a bounded analysis pipeline.

Their purpose is to produce structured environmental and route information that other systems may consume through public interfaces.

Arena Analysis does not automatically authorize or execute movement.

2. Pipeline Structure

The conceptual processing sequence is:

1. L1 observes environmental geometry.
2. L2 evaluates candidate relationships between observed surfaces.
3. L3 evaluates observation freshness and coverage uncertainty.
4. L4 compares hypothetical routes using candidate connections.
5. L5 evaluates route segments against a supplied movement envelope.

Not every stage must be enabled for every analysis operation.

3. L1: Arena Geometry Observer

Role: Collects bounded observations of environmental geometry.

Responsibilities

- Perform configured raycast observations.
- Identify observed surfaces.
- Record geometric information.
- Produce bounded observation results.

Documented bounds

- Default raycast count: 25.
- Maximum raycast count: 49.
- Up to 16 radial sectors plus a center observation.

Boundaries

- A ray that does not hit an object does not prove that the entire direction is clear.
- Observations are limited by the configured scan.
- The result is an observation sample, not a complete representation of the environment.

4. L2: Reachability Analyzer

Role: Evaluates candidate connections between observed surfaces.

Responsibilities

- Compare bounded surface pairs.
- Produce candidate connection relationships.
- Classify candidate movement relationships such as Walk, Jump, and Drop.

Documented bounds

- Maximum 17 surfaces.
- Maximum 136 pair comparisons.

Boundaries

- Candidate connections are heuristic.
- A candidate edge does not guarantee physical reachability.
- Actual movement depends on character capabilities, dynamic obstacles, and runtime conditions.

5. L3: Spatial Confidence Integrator

Role: Evaluates uncertainty associated with observation freshness and coverage.

Responsibilities

- Track observation age.
- Evaluate coverage.
- Produce uncertainty-aware information.
- Optionally use caller-owned evidence stores.

Documented weighting

- Observation age: 0.4.
- Coverage: 0.6.

These are configured heuristic weights, not calibrated statistical probabilities.

Boundaries

- High confidence does not guarantee correctness.
- Low confidence does not prove that an observation is false.
- Unobserved areas must remain distinguishable from observed areas.

6. L4: Route Laboratory

Role: Compares hypothetical routes using the candidate connection graph.

Responsibilities

- Accept caller-selected start and goal surface identifiers.
- Evaluate directed candidate connections.
- Calculate bounded route alternatives.
- Compare route costs using configured heuristics.
- Account for available uncertainty information.

Documented bounds

- Up to four route alternatives.
- Bounded candidate graph and route exploration.

Boundaries

- Does not perform new world scans during route comparison.
- Does not execute routes.
- Does not independently select the user's target or destination.
- A lower heuristic cost does not guarantee a better real-world route.

Known interface

"RouteLaboratory.new(config)"

"Compare(report, startSurfaceId, goalSurfaceId, spatialConfidence?, stores?)"

"Destroy()"

7. L5: Movement Feasibility Analyzer

Role: Evaluates hypothetical route segments against a supplied movement envelope.

Responsibilities

- Accept route information.
- Evaluate route legs against supplied movement limits.
- Produce bounded feasibility classifications.

Documented classifications

- "WithinConfiguredEnvelope"
- "OutsideConfiguredEnvelope"

Documented bound

- Maximum 16 route legs.

Boundaries

- Does not control a Humanoid.
- Does not execute movement.
- Does not independently query the physical character.
- Does not guarantee actual runtime movement success.

Its result is conditional on the supplied movement parameters.

8. ArenaAnalysisPipeline

The consolidated coordinator owns and organizes the L1-L5 components.

Known public interfaces

- "ArenaAnalysisPipeline.new(worldRoot, overrides?)"
- "Observe(origin, characterToExclude?, stores?)"
- "Compare(startSurfaceId, goalSurfaceId, movementEnvelope?, stores?)"
- "GetLatest()"
- "GetCounts()"
- "Destroy()"

Responsibilities

- Coordinate bounded observation.
- Preserve the latest analysis result.
- Coordinate route comparison.
- Expose structured results.
- Manage the lifecycle of its owned L1-L5 components.

Ownership

The pipeline owns its L1-L5 modules.

Caller-owned evidence stores remain caller-owned and must not be destroyed by the pipeline.

9. Relationship With Navigation Architecture

Arena Analysis may provide useful information to:

- Navigation planning.
- Route comparison.
- Movement feasibility checks.
- Diagnostic systems.
- Future behavior coordination.

However, the following responsibilities remain separate:

Responsibility| Owner
Environmental geometry observation| L1
Candidate surface relationships| L2
Spatial uncertainty| L3
Hypothetical route comparison| L4
Movement-envelope evaluation| L5
Actual local movement| Foundation H
Behavior policy| Future behavior layer

An analysis result must pass through the appropriate navigation and movement interfaces before it can influence execution.

10. Operational Characteristics

- Analysis is explicitly invoked.
- Work is bounded by configured limits.
- The pipeline does not require continuous background scanning.
- The pipeline does not independently execute movement.
- Results may become stale as the environment changes.
- Each result should retain enough context to identify its assumptions and limitations.

11. Verification Requirements

Future verification should cover:

1. Raycast bounds and filtering.
2. Surface identification.
3. Candidate connection generation.
4. Uncertainty calculations.
5. Route comparison bounds.
6. Movement-envelope evaluation.
7. Caller-owned store preservation.
8. Pipeline cleanup.
9. Invalid or stale input handling.
10. Integration with Navigation Core.

12. Important Limitations

Arena Analysis is an approximation and reasoning layer.

It does not establish:

- Complete environmental knowledge.
- Guaranteed physical reachability.
- Guaranteed route execution.
- Perfect prediction of dynamic obstacles.
- Guaranteed movement success.

Its outputs should remain distinguishable from actual movement observations and execution results.
