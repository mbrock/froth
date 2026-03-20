# Distributed Execution Fabric

General-purpose clustered execution infrastructure for Froth.

This sits one level above browser rendering, scraping, or any specific
workload. The browser/video system should be one specialization of this
fabric, not the fabric itself.

## Thesis

Froth needs a durable way to describe work, an ephemeral way to execute work,
and a reliable way to commit results.

That is the classic distributed computation pattern:

- durable intent
- leased execution
- immutable artifacts
- reducer-owned commits

In Froth terms:

- `Oban` is the durable intent layer
- `Phoenix Channels` + `Presence` are the live coordination layer
- worker runtimes are the ephemeral execution layer
- object storage is the artifact layer
- Postgres is the canonical metadata and state transition store

## Core abstractions

These should become the shared vocabulary of the system.

### 1. Job

A durable desired outcome.

Examples:

- render one podcast reel
- scrape one website snapshot
- run one long agent workflow
- batch-convert a media set

A job is not a worker and not a process. It is the thing we want done.

### 2. Task

A small, idempotent unit of work within a job.

Examples:

- render frames `0..119`
- transcode segment `03`
- fetch one URL
- embed one document chunk

Tasks should be shaped so they can be retried, reassigned, or dropped without
corrupting the job.

### 3. Worker

An ephemeral executor advertising capabilities and available slots.

Examples:

- headless browser worker
- ffmpeg worker
- GPU image generation worker
- shell executor
- human operator

Workers are replaceable. They may disappear at any time.

### 4. Lease

A temporary right for one worker to execute one task.

The lease is the key abstraction that keeps the system sane:

- a task is not "owned forever"
- a task is only assigned for a bounded time
- if the worker dies or stops heartbeating, the lease expires
- expired work returns to the queue

### 5. Artifact

An immutable output written to shared storage.

Examples:

- PNG frame bundle
- MP4 segment
- JSON scrape result
- screenshot
- trace log

Workers should report artifacts; they should not directly mutate final job
state beyond their lease outcome.

### 6. Reducer

The thing that validates artifacts and advances the job state machine.

Examples:

- verify all frame batches are present, then enqueue mux
- verify all scrape shards are present, then merge
- verify partial outputs, then publish final result

Reducers own commits. Workers do not.

## The five planes

This is the useful "Aristotelian" layer of the design.

### 1. Control plane

Durable intent and orchestration.

Responsibilities:

- create jobs
- expand jobs into tasks
- track retries and cancellation
- enforce job state transitions
- enqueue follow-up stages

Backed by:

- `Oban`
- Postgres tables owned by Froth

### 2. Coordination plane

Live matchmaking between workers and tasks.

Responsibilities:

- worker roll call
- capability advertisement
- lease assignment
- heartbeats
- revocation
- progress fanout

Backed by:

- `Phoenix Channels`
- `Phoenix Presence`
- `Phoenix PubSub`

This is where the "render farm roll call" lives.

### 3. Execution plane

The actual runtimes that do work.

Examples:

- supervised Chromium instances
- BEAM processes
- shell commands
- ffmpeg subprocesses
- GPU workers

Execution is intentionally ephemeral and local to a node.

### 4. Data plane

Artifacts and payloads moving through the system.

Examples:

- HTML render specs
- frame segments
- browser screenshots
- logs
- JSON results

Backed by:

- object store
- local temp files
- artifact metadata rows in Postgres

### 5. Observation plane

How humans and automation see what is happening.

Responsibilities:

- telemetry
- logs
- progress streams
- operator dashboards
- intervention controls

Backed by:

- `Froth.Telemetry`
- PubSub topics
- LiveViews
- task transcripts

## Design rules

These should be held quite strictly.

### Durable truth lives on the server

Browsers and workers must not become the source of truth for job state.

They can:

- request leases
- report progress
- upload artifacts
- complete or fail a lease

They should not:

- inspect Oban directly
- mutate canonical job state directly
- decide the final outcome of the whole job

### Workers are cattle

Any worker can vanish. That should be normal.

So:

- every lease expires
- every task is retryable
- every artifact is immutable
- reducers are idempotent

### Artifacts beat in-memory results

If a result matters, write it to storage and then report its identity.

Do not let expensive work exist only in a worker process mailbox.

### The reducer owns the commit

A worker says "I produced artifact X."

The reducer says:

- artifact accepted
- task complete
- next stage unlocked

That separation is what keeps replay and recovery possible.

### Workloads specialize the fabric

Video rendering, browsing, scraping, and long agent tools should be different
workload types, not different infrastructures.

## Worker protocol

This is the shape of the live protocol between workers and the coordinator.

It should be small and boring.

### Worker -> coordinator

- `hello`
- `heartbeat`
- `request_lease`
- `batch_started`
- `progress`
- `artifact_uploaded`
- `complete`
- `fail`
- `release`

### Coordinator -> worker

- `welcome`
- `lease_granted`
- `no_work`
- `revoke`
- `cancel_job`
- `ack`

### Worker hello payload

Includes:

- `worker_id`
- `worker_type`
- `node`
- `hostname`
- `slots`
- `capabilities`
- `version`

Example capabilities:

- `browser`
- `headless`
- `viewport: "1080x1920"`
- `codec: "h264+aac"`
- `gpu: false`

## Presence model

`Presence` should track live worker availability, not durable work state.

Example topic:

- `compute:workers:browser`

Metadata:

- `worker_id`
- `node`
- `slots_total`
- `slots_free`
- `busy_jobs`
- `capabilities`
- `last_heartbeat_at`

That gives us a live view of the fleet without confusing presence with
durability.

## Data model

The exact schema can vary, but conceptually we want these durable entities.

### `compute_jobs`

- `id`
- `type`
- `status`
- `args`
- `priority`
- `inserted_at`
- `started_at`
- `finished_at`
- `cancelled_at`
- `error`

### `compute_tasks`

- `id`
- `job_id`
- `stage`
- `kind`
- `status`
- `lease_token`
- `attempt`
- `payload`
- `worker_id`
- `lease_expires_at`
- `started_at`
- `finished_at`
- `error`

### `compute_artifacts`

- `id`
- `job_id`
- `task_id`
- `kind`
- `uri`
- `metadata`
- `checksum`
- `size`
- `inserted_at`

### `compute_events`

Optional, append-only.

- `job_id`
- `task_id`
- `kind`
- `payload`
- `inserted_at`

This is useful for auditing, debugging, and operator UI replay.

## Froth module layout

At the general level:

- `Froth.Compute`
- `Froth.Compute.Job`
- `Froth.Compute.Task`
- `Froth.Compute.Lease`
- `Froth.Compute.Artifact`
- `Froth.Compute.Coordinator`
- `Froth.Compute.Dispatcher`
- `Froth.Compute.Store`
- `Froth.Compute.WorkerSupervisor`
- `FrothWeb.ComputeWorkerChannel`
- `FrothWeb.ComputePresence`
- `FrothWeb.ComputeLive`

At the workload level:

- `Froth.Render` for video/browser rendering
- `Froth.Crawl` for browser scraping
- `Froth.AgentExec` for long-running agent workloads

## LiveView's role

LiveView is not the compute fabric.

LiveView is:

- an operator console
- a bootstrap shell for human-visible render surfaces
- a debugging/preview surface

Channels + Presence are the lower-level coordination mechanism for actual
worker leasing.

For browser workloads, a worker browser may load a LiveView route, but the
lease protocol should still run through Channels.

That gives us the nice property that:

- a human can open the same route and watch
- a headless browser can open the same route and work
- the workload remains server-coordinated

## Video rendering as a specialization

The browser/video system should sit on top of this fabric.

### Job

- "render reel `R`"

### Tasks

- render segment `00`
- render segment `01`
- render segment `02`
- mux final output

Prefer segment-level tasks over raw per-frame tasks as the stored unit.
Inside a segment, the renderer can still step frame-by-frame with exact timing.

### Workers

- browser workers with Chromium and CDP

### Lease payload

- render spec location
- frame range or segment range
- viewport
- fps
- artifact upload target

### Artifact

- segment MP4
- optional contact sheet / preview image
- logs / traces

### Reducer

- wait for all segments
- verify continuity
- enqueue final mux
- publish output artifact

## Browser specialization

The browser worker model becomes:

1. Worker boots on some node.
2. Worker checks out a local Chromium under `Froth.Browser.Supervisor`.
3. Worker opens a render route such as `/froth/render/:token`.
4. A JS hook joins `compute:workers:browser`.
5. Coordinator grants a lease.
6. Worker renders its assigned segment.
7. Worker uploads artifact to the store.
8. Worker reports completion and requests another lease.

The browser never reads Oban directly.

## Why this is better than "browser reads the queue"

Because the queue and the browser solve different problems.

Oban is good at:

- durability
- retries
- scheduling
- cancellation
- cluster-wide ownership

Channels/Presence are good at:

- liveness
- matchmaking
- low-latency leasing
- roll call
- progress streams

Making browsers consume the durable queue directly mixes these concerns and
makes failure handling harder.

## Operator experience

The fabric should make intervention easy.

Operators should be able to:

- inspect active jobs
- see live workers
- revoke a lease
- cancel a job
- retry failed tasks
- drain one worker type
- view artifacts and logs

This likely wants a LiveView admin surface backed by PubSub and the compute
event log.

## Suggested implementation order

Build this in layers.

### Phase 1: vocabulary + durability

- job/task/artifact schemas
- status transitions
- reducer primitives
- no worker fleet yet

### Phase 2: live coordination

- worker channel
- presence
- lease API
- heartbeat expiry

### Phase 3: browser specialization

- `Froth.Render`
- `RenderLive`
- browser worker JS hook
- segment rendering tasks

### Phase 4: operator console

- fleet view
- active jobs
- lease revocation
- artifact browser

### Phase 5: second workload

Add another workload, such as browser scraping, to prove the abstraction is
general and not just a video wrapper.

## One-sentence summary

The platonic form here is a lease-based distributed execution fabric:
durable jobs, ephemeral workers, immutable artifacts, and reducer-owned
commits.

Created: 2026-03-20
