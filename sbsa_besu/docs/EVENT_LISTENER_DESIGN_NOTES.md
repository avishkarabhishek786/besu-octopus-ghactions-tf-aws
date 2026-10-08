# Event Listener (SWIFT actions) — Design Record & Decisions

**Date:** 2026-08-18
**Status:** High-level design agreed. **Transport DECIDED (E-13): SNS FIFO + SQS FIFO primary;
Amazon MSK (Kafka) retained as documented option 2.**
**Scope:** Companion to `CLOUD_TEAM_REDESIGN_NOTES.md`. Seeds the **NEW, SEPARATE git project**.
The current `besu-aws` repository is **unchanged**; nothing here is to be applied to this repo.
**Standing constraints inherited:** single VPC (CT-1), private subnets / air-gap (CT-2, D-3),
all images from a private ECR registry (CT-3/CT-3a), ~~`/20` CIDR (D-7), dedicated chain EKS
cluster (D-4), PrivateLink retained (D-1)~~, NetworkPolicy default-deny mandatory (D-9).
**Hard constraint from the human: NO Lambda functions anywhere.**

> **⚠️ CT-5, 2026-09-21 — three of the inherited constraints are gone, and E-14 changes with
> them.** The cloud team provides a **shared EKS cluster** and allots us a **namespace**; we
> build no cluster (`CLOUD_TEAM_REDESIGN_NOTES.md` §12, D-23). So:
>
> - **There is no "CHAIN EKS" and no "APP EKS"** — one cluster, two namespaces requested
>   (#27). The §2 diagram's two boxes become two namespaces in one cluster.
> - **E-14 is re-scoped, not reversed.** The listener still runs **apart from the
>   validators** — that was always the point — but in the **application namespace**, reaching
>   the chain **in-cluster** rather than over PrivateLink (D-28). The isolation it relied on
>   (D-4) is re-requested as a dedicated, tainted **node group** (#28) and otherwise rests on
>   `NetworkPolicy` default-deny (D-9, #35), which is now load-bearing rather than additive.
> - **PrivateLink is no longer a data-path dependency**, which *removes* the risk this
>   document flagged: §6a of the platform brief warned that E-14 made the unvalidated
>   same-VPC PrivateLink path load-bearing. That concern is void, along with the Stage 3.0 gate.
> - **Unchanged:** everything that matters here — E-1..E-13 and E-15..E-20, the cursor
>   semantics, the event ID, the FIFO dedupe, single-writer nonce management, no Lambda. The
>   `sqs`/`sns` endpoints are now the cloud team's to provide (D-11), not ours to create.

**Revision note (2026-08-18):** the first draft of this document was written Kinesis-first, as
briefed. The human selected **SQS FIFO + SNS**, with Kafka kept open as option 2. This revision
carries that decision through every affected section — the change is not confined to the
middle box (see §2.4 and §5.3 for the two consequences that are easy to miss). Kinesis Data
Streams is retained only in the §6 comparison, as a rejected option with its reasoning intact.

**Revision note 2 (2026-08-18):** EQ-2 elaborated into **§9.1 — the adapter contract**, after
the observation that "which protocol?" is a proxy for four contract questions that have to be
asked regardless of the answer. Added **E-20** (delete only after a durable ack) and **E-21**
(every adapter behind one stable interface). **EQ-6 reverted from MOOT to CONDITIONALLY OPEN** —
an MQ-with-Java answer to EQ-2 re-introduces the Maven dependency that dropping KCL removed.

---

## 0. Why this document exists

The bank needs a system that captures Besu contract events, processes them, and hands them
to other bank applications — for both SWIFT-initiated and self-initiated transactions —
"seamlessly and without interruption and data loss."

The brief asked for an AWS Kinesis based architecture and for better alternatives to be named
if they existed. They did, and one was selected. This file records the design, the reasoning
behind each decision, the option comparison as assessed, and what the design adds to the
cloud-team constraints already captured in `CLOUD_TEAM_REDESIGN_NOTES.md`.

---

## 1. The architectural premise (everything follows from this)

**The chain is already a durable, ordered, replayable log.**

- Besu retains every receipt and log. Bonsai prunes *state*, not receipts — `eth_getLogs`
  over historical ranges keeps working.
- `eth_getLogs` is a range query over immutable history.
- QBFT has **immediate finality** — a block committed with 2F+1 commit seals is final.
  There is no reorg window to wait out, unlike PoW/PoS Ethereum.

**Consequence:** "no data loss" is not a queue-durability problem. It is a
**cursor + idempotency + reconciliation** problem. The messaging tier is *transport and
fan-out*, never the system of record.

- Get the cursor semantics right → any downstream loss is repairable by rewinding.
- Get them wrong → no amount of queue retention saves you.

This premise is what made the transport genuinely swappable (§6), and it is what makes SQS's
one real weakness — **no replay after consumption** — an acceptable trade rather than a
disqualifier. It is also why the reconciliation job (§4.1) is non-optional.

---

## 2. Reference architecture

```
 LEDGER NAMESPACE (was: CHAIN EKS, D-4)    APP NAMESPACE (was: APP EKS)   [CT-5]
 ┌──────────────────────────┐              ┌────────────────────────────────────────┐
 │ validators (QBFT x4)     │              │  chain-tailer (Deployment, leader-     │
 │ swift-rpc pool (mTLS) <──┼── SWIFT      │   elected via k8s Lease)               │
 │ app-rpc pool ────────────┼─in-cluster───┤   eth_getLogs(from,to) loop            │
 └──────────────────────────┘              │   cursor -> DynamoDB (only after ACK)  │
                                           └───────────────┬────────────────────────┘
                                                           │ Publish
                                                           │  MessageGroupId  = UETR
                                                           │  MessageDedupeId = sha256(eventId)
                                              ┌────────────▼─────────────┐
                                              │ SNS FIFO topic           │  KMS CMK
                                              │ chain-events.fifo        │  fan-out only
                                              └──┬───────────┬────────┬──┘
                                                 │           │        │
                                    ┌────────────▼──┐  ┌─────▼─────┐  └──> (future consumers)
                                    │ SQS FIFO      │  │ SQS FIFO  │
                                    │ processing    │  │ archive   │
                                    │  .fifo        │  │  .fifo    │
                                    └───┬───────────┘  └─────┬─────┘
                                        │ long-poll          │ long-poll
                                  ┌─────▼───────────┐  ┌─────▼──────────┐
                                  │ processor pods  │  │ archiver pods  │
                                  │ validate, map   │  │ batch -> S3    │
                                  │ to ISO 20022 /  │  │ (Parquet)      │
                                  │ canonical form  │  └─────┬──────────┘
                                  └───┬─────────┬───┘        │
                                      │         │            ▼
                                      │         │      ┌───────────────┐
                                      │         │      │ S3 audit lake │
                                      │         │      │ (reconcile    │
                                      │         │      │  source)      │
                                      │         │      └───────────────┘
                                      │         └──> DLQ (redrive policy) + alarm
                                 ┌────▼──────────────┐
                                 │ bank adapters     │──> IBM MQ / internal mTLS API
                                 │ (idempotency key) │    key = chainId:txHash:logIndex
                                 └───────────────────┘

 Separate concern (outbound submission — NOT part of the listener):
   tx-submitter (leader-elected, single nonce writer) ──PrivateLink──> app-rpc
        intent outbox (DDB/RDS) -> sign -> send -> receipt reconciler -> TxStatus -> same topic
```

### 2.1 Component 1 — `chain-tailer` (the event listener proper)

Runs in **APP EKS** (E-14), reaches the chain's `app-rpc` pool over PrivateLink.
**Unchanged by the transport decision** — this component is transport-agnostic by design (E-5).

- **Poll, do not subscribe.** `eth_subscribe`/WebSocket is a bad primary source: a dropped
  socket silently loses every event that occurred while disconnected, and offers no replay.
  Primary path is `eth_getLogs(fromBlock, toBlock, address[], topics[])` in batches against a
  durable cursor. A WS subscription may be kept purely as a **wake-up hint** to cut latency —
  never as the source of records. (E-2)
- **Batch size must stay under Besu's `--rpc-max-logs-range`** (default 5000). Parameterise it;
  do not hardcode (no-hardcoding rule).
- **Contiguity assertion.** Track `parentHash` continuity block-to-block. A break means either
  a gap (bug, or an RPC node lagging) or a reorg — both alarm and rewind. Free gap detector.
- **Cursor advances only after the SNS publish is acknowledged** (E-4). That makes
  chain->topic at-least-once. A crash between publish and checkpoint replays a few records;
  the deterministic event ID absorbs them.
- **Leader election** via a Kubernetes `Lease` (`coordination.k8s.io`) so exactly one publisher
  is active. A brief split-brain is survivable *because* of the dedupe key — belt and braces.
- **Keep it dumb** (E-5). Its only job is: chain range -> normalized envelope -> topic.
  No business logic. A processing bug must never be able to stop ingestion, and logic fixes
  should be replayable from the archive rather than requiring a chain rewind.
- **Cursor store remains DynamoDB** (gateway endpoint, free). Note this is *not* the KCL lease
  table — that is gone with Kinesis (§5.2). The cursor is our own, and it survives every
  transport choice.

**Event ID — the load-bearing detail (E-3):**

```
chainId : blockHash : txHash : logIndex
```

Deterministic, globally unique, derived entirely from the chain — two independent runs of
the tailer produce identical IDs. Uses `blockHash`, **not** `blockNumber`, so a hypothetical
reorg yields a *different* ID rather than a silent conflict. This value is the idempotency
key at every downstream boundary.

> ⚠️ **Length trap.** `MessageDeduplicationId` and `MessageGroupId` are capped at **128
> characters**. The raw event ID is ~143 characters (two 0x-prefixed 32-byte hashes), so it
> **does not fit**. Publish `MessageDeduplicationId = sha256(eventId)` as hex (64 chars) and
> carry the full event ID in the message body. A UETR is a 36-character UUID and fits
> `MessageGroupId` unmodified. (E-18)

### 2.2 Component 2 — SNS FIFO topic (fan-out)

- **SNS exists purely for fan-out.** SQS FIFO delivers each message once, to one consumer —
  there is no Kafka-style consumer group. Multiple independent consumers therefore mean
  multiple queues, and SNS is the mechanism that feeds them all from one publish.
- **FIFO topic, not standard.** Required to preserve ordering and to get the dedupe window.
- `MessageGroupId` is **mandatory** on publish to a FIFO topic. Ordering is per group (E-7).
- Set `MessageDeduplicationId` **explicitly** (see the length trap above) rather than relying
  on content-based deduplication — the envelope may carry a timestamp or a producer field that
  would defeat content hashing.
- **KMS CMK encryption**, consistent with the C12 node-key custody pattern.
- **Throughput:** the per-topic FIFO quota is far above the expected envelope (§8, EQ-3), but
  per the verify-don't-assume rule, **confirm the current per-topic quota at design time**
  rather than trusting a figure recorded here.

> ⚠️ **The constraint that shapes §2.4: an SNS FIFO topic can deliver ONLY to SQS FIFO queues.**
> Firehose, HTTP/S, email and Lambda subscriptions are supported on *standard* topics only.
> Anything that needs one of those protocols must be fed from a queue by one of our pods, not
> subscribed to the topic directly. This is not a limitation we can design around later.

### 2.3 Component 3 — SQS FIFO queues + consumers (plain pollers, no Lambda)

Consumers are ordinary long-polling `ReceiveMessage` loops in EKS pods, in **any language** —
no client library, no lease table, no shard arithmetic, no JVM. Replicas scale horizontally;
SQS preserves ordering across replicas because it will not deliver a second message from a
message group while one from that group is still in flight.

- **Retention: 14 days** (the SQS maximum, and better than the 7 days the Kinesis draft
  configured). A long-weekend downstream outage never forces a chain rewind.
- **Visibility timeout** set to comfortably exceed the p99 processing time, or a slow consumer
  will cause redelivery and duplicate work.
- **DLQ via redrive policy** with `maxReceiveCount`. Native — no custom parking store, which
  the Kinesis design needed (E-10).
- **Message size cap is 256 KB.** Chain event envelopes are small, so this is fine as designed
  — but if an event ever carries a large payload (e.g. an encoded ISO 20022 message in
  calldata), use the **claim-check pattern**: body to S3, reference in the message. See EQ-7.

> ⚠️ **"Exactly-once" is a 5-minute window, not a guarantee (E-17).** SQS FIFO deduplication
> covers a **5-minute** interval. It is a cheap first line of defence, nothing more. A
> redelivery after a 20-minute outage will **not** be caught by it. **The real mechanism
> remains application-level idempotency on the event ID (E-3), enforced in every consumer and
> at the bank adapter boundary.** Do not let "SQS FIFO gives exactly-once" enter a design
> review unqualified — it is the single most likely way this pipeline acquires a duplicate
> payment.

**Poison-pill behaviour is better than the Kinesis equivalent, and worth stating:** a stuck
message blocks **only its own message group**, not the whole shard. One stalled payment does
not stall unrelated payments. It *does* stall that payment's subsequent messages until the
visibility timeout expires or the message is redriven, so **keep `maxReceiveCount` low** —
a poison pill should reach the DLQ in seconds-to-minutes, not hours. (E-10)

### 2.4 Component 4 — the archive branch (E-11, REVISED)

**Firehose cannot be used here.** Firehose accepts Direct PUT, Kinesis Data Streams and MSK as
sources — **not SQS** — and it cannot subscribe to an SNS **FIFO** topic (§2.2). The Kinesis
draft's `stream -> Firehose -> S3` path does not survive the transport change.

**Replacement:** a **dedicated `archive` SQS FIFO queue** subscribed to the same SNS FIFO
topic, drained by **archiver pods** that batch records and write **Parquet to S3**.

Why this is fine, and arguably better:

- The archiver is just another consumer — same at-least-once semantics, same event-ID dedupe,
  same DLQ, same alarms. No new failure model to reason about.
- It removes Firehose entirely, so **one fewer AWS service to mirror, endpoint, and pay for**
  under CT-2.
- Batching and partitioning are ours to control (by block date / originator), which is what
  the reconciliation job (§4.1) actually wants.
- Cost: pod CPU instead of Firehose per-GB.

The S3 archive remains the **independent audit trail and the source side of reconciliation** —
and it is what an auditor will actually ask for.

---

## 3. Both flows are ONE listener (E-6)

The brief describes two flows — SWIFT invoking our contracts, and us invoking our contracts.
**They do not need two pipelines.** An event emitted by a transaction *we* submitted comes out
of the same `eth_getLogs` tail as one emitted by a SWIFT transaction; the chain does not
distinguish them. Add an `originator` dimension to the envelope (from `msg.sender` / the tx
`from` address) and **route on it downstream**. One ingestion path, one cursor, one topic,
one reconciliation.

### 3.1 What *is* genuinely different: the submission side (E-8)

Outbound transaction submission is a **separate service** from the listener:

- **Intent outbox first.** Persist "intent to send tx" durably, *then* sign and submit, then
  record the txHash. Crash-safe: on restart you know exactly what was in flight.
- **Nonce management is the footgun.** Parallel replicas racing on one signer account produce
  stuck or replaced transactions. Either leader-elect a single submitter per signer key, or
  shard by giving each replica its own signer account. On a **zero-gas chain** you lose the
  "bump the gas price to unstick it" escape hatch, so correct nonce ordering matters *more*,
  not less.
- **Receipt reconciler** polls for receipts and publishes a `TxStatus` record onto the same
  topic, so downstream sees the full lifecycle (submitted -> mined -> event) rather than only
  the terminal event. Publish `TxStatus` under the **same `MessageGroupId`** as the business
  event so a payment's lifecycle stays ordered end to end.

### 3.2 Idempotency belongs in the contract too (E-9)

SWIFT retrying `eth_sendRawTransaction` with the *same signed payload* is free — same tx hash,
same nonce, the chain rejects the duplicate. But a retry that **re-signs with a fresh nonce**
produces a genuine second on-chain event that **no pipeline-level dedupe can distinguish from
a real second payment** — and certainly not a 5-minute SQS window (E-17).

**Enforce business-level idempotency in the Solidity contract** — e.g.
`mapping(bytes32 uetr => bool processed)` with a revert or a no-op emit. That is the only
layer where it can be enforced correctly.

---

## 4. Where each "no data loss" property comes from

| Failure | What saves you |
|---|---|
| Tailer pod dies mid-batch | Cursor only advances post-ACK -> replay; dedupe on event ID |
| SNS publish fails | Cursor does not advance; retry with backoff |
| Consumer dies mid-record | Visibility timeout expires; message is redelivered to another pod |
| Consumer crashes repeatedly on one record | `maxReceiveCount` -> DLQ; **only that message group stalls** |
| Downstream bank system down | Messages age in the queue (14d); age alarm; DLQ after N receives |
| Queue retention exceeded | **Rewind the tailer cursor and re-read the chain** — the ultimate backstop |
| Silent gap (RPC node lagging) | `parentHash` contiguity check -> alarm + auto-rewind |
| Duplicate delivery inside 5 min | SQS FIFO dedupe window (first line only) |
| **Duplicate delivery after 5 min** | **Application-level event-ID idempotency (E-3/E-17) — the real mechanism** |
| SWIFT re-signs and resubmits | Contract-level `uetr` dedupe (§3.2) — nothing else can catch this |
| A consumer deletes a message it should not have | S3 archive retains it; chain rewind if the archive is also wrong |
| Nobody noticed a drift | **Scheduled reconciliation job** (E-12) — see below |

### 4.1 Reconciliation is mandatory (E-12)

A scheduled job compares, over a window: events on chain (`eth_getLogs`) vs. records in the
S3 archive vs. records acknowledged by the downstream bank system. Alarm on any mismatch.

This is the row people skip and the one a bank audit will ask about. **Not optional.**

It also carries more weight here than it did in the Kinesis draft: SQS has **no replay after
consumption**, so reconciliation is the only routine mechanism that will *notice* a message
that was consumed and then lost inside a consumer. The remedy — a cursor rewind — is
unchanged and always available (E-1), but it has to be triggered by something.

### 4.2 Alarms

- **`ApproximateAgeOfOldestMessage` per queue is the single most important metric** — the best
  "am I falling behind" signal (the SQS analogue of Kinesis iterator age). Alarm >60s, page >300s.
- `ApproximateNumberOfMessagesVisible` — backlog depth.
- **SNS `NumberOfMessagesPublished` vs. each queue's `NumberOfMessagesReceived`** — catches a
  broken or misconfigured subscription, i.e. silent fan-out drift. A queue that stops receiving
  looks identical to a quiet period without this.
- DLQ `ApproximateNumberOfMessagesVisible` > 0.
- SNS `NumberOfNotificationsFailed`.
- Tailer **RPC error rate** — a broken PrivateLink endpoint yields *zero events with no error
  from the chain side*, so pod health alone will not catch it.
- Cursor lag (head block minus cursor block).
- Reconciliation drift != 0.

### 4.3 Latency budget

QBFT block time + poll interval (~1-2s) + SNS fan-out (~sub-second) + SQS long-poll
(~1s) ≈ **under 10 seconds** chain->bank. Adequate for payments. If sub-second is ever
demanded, add the WS wake-up hint to shorten the first hop — the rest is already fast.

---

## 5. What the SQS FIFO decision changed

Recorded explicitly so the delta from the Kinesis draft is auditable.

### 5.1 What got simpler

| Removed | Consequence |
|---|---|
| KCL 3.x client library | Consumers are plain pollers in **any language** — the TypeScript team keeps its stack |
| MultiLangDaemon | No second (JVM) runtime per pod; debugging story stays normal |
| DynamoDB **lease** table | One fewer stateful dependency (the tailer **cursor** table stays — different thing) |
| Shard count / partition math | No sizing decision, no `WriteProvisionedThroughputExceeded` |
| Enhanced Fan-Out cost decision | Fan-out is SNS's job, priced per publish |
| Custom DLQ parking store | Native redrive policy with `maxReceiveCount` |
| Kinesis Data Firehose | One fewer managed service to mirror and endpoint (§2.4) |

### 5.2 What got better

- **Retention 7d -> 14d.**
- **Poison-pill blast radius: one shard -> one message group.** A stalled payment no longer
  stalls unrelated payments.
- **Consumer language is unconstrained**, which resolves the biggest practical objection to
  the Kinesis design.

### 5.3 What got worse, and why it is acceptable

- **No replay after consumption.** Kinesis lets any consumer re-read within retention; SQS
  does not — a deleted message is gone. **Acceptable only because of E-1:** the chain is the
  replay source and a cursor rewind reconstructs anything, and the S3 archive covers routine
  re-reads without touching the chain. **This is the single trade the decision buys**, and it
  is why §4.1 reconciliation moved from important to load-bearing.
- **Fan-out is now a topology decision, not a runtime one.** A new consumer needs a new queue
  and subscription (Terraform), where Kinesis needed only a new application. Fine at this
  scale; it is one of the triggers for reconsidering Kafka (§6.1).
- **SNS FIFO cannot serve non-SQS protocols** (§2.2) — any future HTTP or Firehose consumer
  must be fed by one of our pods.

### 5.4 Cost

Materially cheaper at the expected envelope: SQS FIFO and SNS are priced per request with no
always-on component, against ~$22/mo of Kinesis shard-hours plus Firehose per-GB. In absolute
terms the saving is small against the estate — **the operational simplification in §5.1 is the
real return**, not the line item.

---

## 6. Option comparison (as assessed)

| Option | Verdict |
|---|---|
| **SNS FIFO + SQS FIFO** | ✅ **SELECTED (E-13).** Ordering per `MessageGroupId` (= per UETR) is exactly the needed guarantee. Native DLQ. Consumers are plain pollers in any language. 14-day retention. Fewest moving parts of any option that meets the ordering requirement. Costs: no post-consumption replay (§5.3), 256 KB message cap, fan-out is a Terraform change. |
| **Amazon MSK (Kafka)** | 🔶 **OPTION 2 (E-19).** Consumer groups with independent offsets, replay within retention, log compaction, effectively unbounded retention. Native in-VPC ENIs, so **no interface endpoint at all** — a real advantage under CT-2. Costs: ~$300-500/mo minimum, genuine ops burden, and it consumes IPs from the scarce /20. See §6.1 for the triggers. |
| **Kinesis Data Streams** | ❌ Rejected. Sound and replayable, but at this volume it buys replay we can get from the chain, at the price of the KCL/JVM constraint, shard math and a lease table. Reasoning retained in §5. |
| **EventBridge** | ❌ No per-key ordering. Wrong tool for ordered financial flows. |
| **No messaging tier at all** | ❌ Considered and rejected on fan-out grounds. One consumer writing straight to MQ genuinely has fewer failure modes, but the archive branch (§2.4) is a second consumer on day one, and the bank adapter is likely a third. |

### 6.1 Triggers to move to option 2 (Kafka)

Review the decision if **any** of these becomes true:

1. **EQ-5 resolves to "yes"** — the bank's integration layer is already Kafka. This alone is
   probably decisive; matching the downstream teams' stack outweighs the ops cost.
2. **Multiple independent consumer groups need independent replay positions** — the thing
   SQS structurally cannot do.
3. **Retention beyond 14 days is required inside the transport** (rather than in S3).
4. **Volume outgrows the FIFO throughput envelope** (EQ-3).
5. **Stateful stream processing or log compaction** enters the requirements.

### 6.2 Why the switch stays cheap

The migration cost is bounded by design, and this is deliberate:

- The **tailer is transport-agnostic** (E-5) — it emits a normalized envelope. Swapping the
  publisher is a contained change in one component.
- The **event ID is deterministic** (E-3), so a Kafka key derives from the same value with no
  semantic change, and cross-transport dedupe works during a cutover.
- **Consumers change more** — poll loop becomes a consumer-group client — but the business
  logic inside them is untouched.
- A **dual-publish cutover** is possible (publish to both, consumers migrate one at a time,
  dedupe on event ID absorbs the overlap) precisely because idempotency is not transport-derived.

**Do not let transport-specific concepts leak into the envelope schema or the consumers'
business logic.** That discipline is what keeps §6.1 a decision rather than a rebuild.

---

## 7. What this adds to the cloud-team constraints

Cross-references `CLOUD_TEAM_REDESIGN_NOTES.md`.

| Area | Impact |
|---|---|
| **VPC endpoints (§3.2)** | Air-gap requires `sqs` + `sns` interface endpoints: **+2 services x 3 AZ = 6 ENIs, ~$44/mo**. Endpoint list goes **16 -> 18**. Identical count and cost to the Kinesis draft (`kinesis-streams` + `kinesis-firehose`) — **the transport change is endpoint-neutral**, so no revision to the ask is needed. (Option 2 / MSK would need **zero** new endpoints.) |
| **IP budget (§5.3)** | Fixed overhead **155 -> ~161**. Immaterial against the /20, but the table must stay current per §8.2 of the redesign notes. |
| **Registry (CT-3/CT-3a)** | **The language-package question is conditional, not moot — and it got sharper.** ECR is an **OCI registry only**: it cannot host Maven, npm or OS packages at all. Dropping KCL dropped the JVM from the pipeline, but EQ-2 can re-introduce it: the IBM MQ **Java** client needs Maven, and the MQ **Node** client is worse — it wraps IBM's licensed native redistributable, which is not on npm and not trivially mirrored (§9.1.1). Choosing the AMQP 1.0 or MQ REST route avoids the question entirely. See EQ-6. |
| **NetworkPolicy (D-9)** | Explicit egress allow only: tailer -> PrivateLink endpoint ENIs; tailer -> SNS endpoint ENIs; consumers -> SQS endpoint ENIs; archiver -> S3 gateway endpoint. Nothing else. |
| **IRSA + permissions boundary (H5)** | Tailer: `sns:Publish` on one topic ARN. Consumers: `sqs:ReceiveMessage`/`DeleteMessage`/`ChangeMessageVisibility` scoped per queue ARN — **one role per queue, not one shared role**. Archiver: the above plus `s3:PutObject` on one prefix. Boundary-attached per the H5 pattern. |
| **KMS** | CMK on the topic and on every queue, plus the S3 archive bucket. Consumer roles need `kms:Decrypt` on that key only. |
| **No-hardcoding rule** | Topic/queue names, contract addresses, topic filters, batch size, poll interval, visibility timeout, `maxReceiveCount`, retention, endpoint DNS -> all variables threaded from the root module. |
| **PrivateLink (D-1)** | Becomes a **data-path** dependency, not just an app convenience. Same-VPC endpoint behaviour must be covered by the D-1 smoke test in the first deploy-test. |
| **No deletion-protection rule** | Applies to the topic, queues, cursor table and S3 archive — nothing that blocks immediate teardown. |
| **Cost** | SQS/SNS per-request (negligible at this volume); DynamoDB cursor table on-demand ~pennies; endpoints ~$44/mo; S3 storage. Small against the estate, but it counts against the deploy-test cap. |

---

## 8. Decisions log

| ID | Decision | Status |
|---|---|---|
| E-1 | **The chain is the system of record**; the messaging tier is transport/fan-out. No-loss is achieved by cursor + idempotency + reconciliation, not by queue durability. | DECIDED |
| E-2 | **Polling `eth_getLogs` against a durable cursor is the primary ingestion path.** WebSocket `eth_subscribe` may be a latency wake-up hint only, never a record source. | DECIDED |
| E-3 | **Deterministic event ID = `chainId:blockHash:txHash:logIndex`**, used as the idempotency key at every boundary. `blockHash` not `blockNumber`. | DECIDED |
| E-4 | **The cursor advances only after the SNS publish is acknowledged** -> at-least-once + dedupe, never at-most-once. | DECIDED |
| E-5 | **The tailer carries no business logic and no transport-specific concepts.** Processing lives in consumers; this is also what keeps the §6.1 Kafka switch cheap. | DECIDED |
| E-6 | **One listener serves both directions** (SWIFT-initiated and self-initiated); route downstream on an `originator` dimension. | DECIDED |
| E-7 | **`MessageGroupId` = business correlation key (UETR)** -> per-payment ordering, not global total order. Trade-off recorded in §2.2. | DECIDED |
| E-8 | **Transaction submission is a separate service** from the listener: intent outbox, single-writer nonce management, receipt reconciler publishing `TxStatus` under the same `MessageGroupId`. | DECIDED |
| E-9 | **Business-level idempotency is enforced in the Solidity contract** (`uetr` -> processed), because a re-signed retry is indistinguishable downstream. | DECIDED |
| E-10 | **DLQ via native redrive policy** with a **low `maxReceiveCount`**. Never drop silently; a poison pill must reach the DLQ in seconds-to-minutes, since it stalls its message group meanwhile. | DECIDED |
| E-11 | **Archive branch = dedicated `archive` SQS FIFO queue + archiver pods -> S3 Parquet.** Firehose is unusable here (no SQS source, no SNS FIFO subscription) — §2.4. | **REVISED** 2026-08-18 |
| E-12 | **Scheduled chain-vs-archive-vs-downstream reconciliation is mandatory**, and is load-bearing given SQS has no post-consumption replay. | DECIDED |
| E-13 | **Transport = SNS FIFO + SQS FIFO.** Chosen over Kinesis for ordering-per-payment with far fewer moving parts and no language constraint. | **DECIDED** 2026-08-18 |
| E-14 | ~~**The listener runs in APP EKS** (not the chain cluster), reaching the chain via PrivateLink — preserves D-4 isolation~~ → **RE-SCOPED by CT-5/D-28 (2026-09-21): the listener runs in the APPLICATION NAMESPACE**, reaching the chain **in-cluster**. The intent is unchanged — the tailer never shares a failure domain or a node with the validators — but it is now enforced by namespace + `NetworkPolicy` (D-9) and, if #28 is granted, by a validator taint, instead of by a cluster boundary. Keeping app-team churn off the validator nodes becomes the substance of #28. | **RE-SCOPED** |
| E-15 | **No Lambda anywhere.** All consumers are EKS pods; the archive path is a pod, not Firehose. | DECIDED (human constraint) |
| E-16 | **SNS FIFO is used for fan-out only**, because SQS FIFO has no consumer-group concept. Each independent consumer gets its own queue + subscription. | DECIDED |
| E-17 | **SQS FIFO deduplication (5-minute window) does NOT satisfy the idempotency requirement.** Application-level event-ID idempotency is mandatory in every consumer and at the bank adapter. | DECIDED |
| E-18 | **`MessageDeduplicationId` = `sha256(eventId)`** (64 chars) because the raw event ID exceeds the 128-character cap; the full event ID travels in the body. `MessageGroupId` = UETR (36 chars, fits). | DECIDED |
| E-19 | **Amazon MSK (Kafka) is retained as option 2**, with explicit reconsideration triggers (§6.1) and a bounded migration path (§6.2). Not a rejected option — a deferred one. | DECIDED |
| E-20 | **The SQS delete is gated on the receiving system's DURABLE ack**, never on a transport-level acknowledgement: MQ `MQCMIT` under syncpoint with `MQPER_PERSISTENT`; an HTTP response returned only *after* durable commit; Kafka `acks=all` with `min.insync.replicas >= 2`. Per-protocol detail in §9.1. | DECIDED |
| E-21 | **Every bank adapter sits behind one stable internal interface** — `deliver(envelope) -> DurableAck \| Retryable \| Poison`. Protocol never leaks into the processor. Applies E-5's portability discipline to the far end, and is what lets EQ-2 resolve to several answers at once without three bespoke codebases. | DECIDED |

---

## 9. Open questions

| # | Question | Impact if unanswered |
|---|---|---|
| EQ-1 | **Which direction does the response to SWIFT actually travel?** SWIFT reaches us *inbound* over SIPN. If a response must go *back* to SWIFT, an outbound SIPN path SWIFT permits is required — materially different work. If the bank's own SWIFT gateway (Alliance Access) owns egress and we hand off internally, this is a non-issue. **Design currently assumes the latter.** | Changes the egress design entirely if wrong. |
| EQ-2 | **What does the receiving bank application speak** — IBM MQ, HTTP/mTLS, Kafka? | Determines the adapter, the durable-ack signal (E-20) and where the idempotency key rides. **Elaborated in §9.1**, including the four contract questions to ask regardless of protocol. If Kafka, see EQ-5 and §9.1.3. |
| EQ-3 | **Expected message volume** (per day, and peak per second)? Design is sized for "hundreds to low thousands per day". | FIFO throughput quota check; trigger #4 for option 2. |
| EQ-4 | **Is per-payment ordering sufficient**, or does a downstream system assume global total order? | Global order means a single `MessageGroupId`, serialising the whole pipeline. Real cost/design implications. |
| EQ-5 | **Does the bank already run Kafka?** | **Now the primary trigger for option 2 (§6.1), not a tiebreaker.** If yes, revisit E-13 before build starts. |
| EQ-6 | **Where would Maven artifacts come from?** ECR **cannot host them** — it is an OCI registry only (CT-3a). A JVM dependency therefore needs a *separate* ask: AWS CodeArtifact (which has its own VPC endpoints) or an S3-hosted repository. | **CONDITIONALLY OPEN** (was MOOT). Dropping KCL dropped the JVM from the pipeline — but EQ-2 can re-introduce it: the IBM MQ **Java** client needs Maven (§9.1.1), as would a JVM Kafka client under option 2. **Resolve EQ-2 before closing this** — the cost of getting it wrong is a new package-repository workstream, not a config change. |
| EQ-7 | **Can any event payload exceed 256 KB?** (e.g. an encoded ISO 20022 message in calldata) | Determines whether the claim-check pattern (body to S3, reference in message) is needed from day one. |

**None of these block the implementation plan** — E-1..E-12 and E-14..E-21 are stable, and
E-13 now has a decision with documented reversal triggers.

### 9.1 EQ-2 elaborated — the adapter contract

EQ-2 is phrased as a protocol question, but **protocol is downstream of four contract
questions**. The adapter is where our at-least-once pipeline meets someone else's system, and
that boundary is where "no data loss" is actually won or lost. Ask these four in writing
whatever the protocol turns out to be; the protocol answer only tells you which trap to watch.

| # | Question to the receiving team | Why it is the real question |
|---|---|---|
| 1 | **What is your durable-ack signal?** | We may not delete the SQS message until the record is *durably persisted* on their side — not "received", not "the load balancer returned 200". Delete on anything weaker and a crash there loses a payment we can no longer replay from the queue. (E-20) |
| 2 | **What is your idempotency contract?** | We are at-least-once (E-3, E-17). They **will** see duplicates. Which field do you index, and what do you do on a repeat? |
| 3 | **Do you need per-payment ordering preserved, and can your side maintain it?** | SQS FIFO's one-in-flight-per-`MessageGroupId` preserves order *to* the boundary. It can still be lost *inside* their system. |
| 4 | **Who owns the endpoint / queue / topic, its credentials, and their rotation?** | Under air-gap (D-3) every credential is a lifecycle we run offline. |

#### 9.1.1 If the answer is IBM MQ

The most likely answer in a payments shop; Alliance Access is MQ-heavy.

**Where the idempotency key rides** — not where people first reach for it:

| Slot | Verdict |
|---|---|
| `MQMD.MsgId` | ❌ 24 bytes, and MQ may regenerate it unless identity context is set explicitly. |
| `MQMD.CorrelId` | ❌ 24 bytes — our `sha256(eventId)` is 32. |
| `MQMD.ApplIdentityData` | 🔶 32 bytes, fits the raw hash, but a legacy slot. |
| **MQ message properties (RFH2, `MQSETMP`)** | ✅ **The right answer** (MQ 7.0+): `bank.idempotencyKey = sha256(eventId)`, `bank.uetr = <UETR>`. |
| Payload envelope | ✅ In addition, for audit, if the body is ISO 20022. |

> ⚠️ **Durability trap — message persistence.** `MQMD.Persistence` must be set explicitly to
> `MQPER_PERSISTENT`. A non-persistent message is lost on a queue-manager restart, by which
> point we have deleted our SQS copy. Put under syncpoint; **the `MQCMIT` is the durable ack
> for question 1.** This is the most common way MQ integrations silently lose messages.

**Ordering:** preserved per queue for same-priority messages put sequentially. Our model
composes cleanly — one in-flight per group means the adapter cannot reorder within a payment.
Their side must read FIFO and not fan out to parallel getters mid-group.

**Dedupe:** MQ has **none**. Question 2 lands entirely on their application, so it must be
settled before build starts. This is the negotiation point.

> ⚠️ **Supply-chain trap (CT-3).** The Node `ibmmq` package wraps IBM's **MQ C client
> redistributable** — a licensed native binary, not on npm and not mirrorable into ECR,
> which holds OCI artefacts only. Three ways out, in order of preference:
> 1. **AMQP 1.0 channel** on the queue manager (MQ 8+) with a pure-JS client such as `rhea` —
>    no native dependency, no licensed download.
> 2. **MQ messaging REST API** via mqweb — plain HTTP, lowest friction; no cross-message
>    transactions and lower throughput, both acceptable at this volume.
> 3. Java client (`com.ibm.mq.allclient`) — **this re-opens EQ-6**, and under CT-3a that
>    means standing up a Maven repository (CodeArtifact or S3) that does not exist today.

**Air-gap:** plain TCP to an IP over the TGW, **no VPC endpoint required** — a CT-2 positive.
We do own an MQ TLS key repository (`.kdb` or JKS) holding their CA, and its rotation.

#### 9.1.2 If the answer is HTTP / mTLS

**Where the key rides:** the `Idempotency-Key` header (a de facto standard with an IETF draft,
not a ratified one), echoed in the body for audit.

> ⚠️ **Durability trap — HTTP 200 is not a durable ack.** If their handler enqueues internally
> and returns `202 Accepted`, a crash behind that response loses the message. Contract
> explicitly for a response returned **only after durable commit**, or for an out-of-band
> confirmation we can wait on.

**The ambiguous timeout.** Send, time out, and we cannot know whether it was processed. We must
retry, and their idempotency has to absorb it — so pin down repeat-key behaviour:

| Their behaviour on a repeated `Idempotency-Key` | Verdict |
|---|---|
| Replays the stored original response | ✅ Correct |
| Returns `409 Conflict` | 🔶 Workable — but **we must treat 409 as success** and delete the message. Get it in writing. |
| Silently reprocesses | ❌ Broken. Do not accept the integration on these terms. |

**Retry classification must be explicit:** 5xx / 429 / timeout are retryable; 400-class
validation failures are poison and go straight to the DLQ. Without that mapping a malformed
record retries to `maxReceiveCount` and stalls its message group throughout (§2.3).

**Ordering:** HTTP carries no ordering semantics. Order survives to their door because of SQS
FIFO, but an internally-async endpoint can lose it behind the response. Ask.

> ⚠️ **mTLS under air-gap:** if they want to check **our** certificate's revocation, we must
> host a CRL reachable on the internal network — no OCSP fetch works in a true air-gap (D-3).
> A bilateral requirement; raise it early rather than at integration test.

✅ **Lowest supply-chain friction of the three:** any HTTP client, no native dependencies,
nothing new to mirror and no package repository to stand up.

#### 9.1.3 If the answer is Kafka — this changes E-13

`SQS FIFO -> adapter -> Kafka` is a translation layer that earns nothing. This is trigger #1 in
§6.1, and the nuance is **whose cluster**:

| Whose Kafka | Consequence |
|---|---|
| **Theirs** (we produce to their brokers) | **SQS *and* MSK both disappear.** The tailer publishes to their topic; our archiver consumes the same topic under its own consumer group. Strictly simpler and cheaper than the current design. |
| **Ours** (MSK, they consume) | Option 2 as recorded in E-19 — we take the ~$300-500/mo and the ops burden, they get a consumer group. Clean. |
| **Both, bridged** | ❌ A MirrorMaker/Connect hop: two clusters, two failure domains, offset translation. Avoid. |

**Where the key rides:** record **key** = UETR (drives partitioning *and* log compaction),
header `idempotency-key` = event ID. Ordering per partition by key maps exactly onto E-7.

> ⚠️ **The same trap as E-17 in a different wrapper.** Kafka's "exactly-once"
> (`enable.idempotence=true`, transactions) is **broker-side and producer-session-scoped**. It
> suppresses duplicates from producer retries within one session and does nothing about our
> tailer replaying after a crash. Application-level event-ID idempotency remains mandatory.

> ⚠️ **Durability trap:** `acks=all` with `min.insync.replicas >= 2`. `acks=1` loses data on
> leader failover — the Kafka equivalent of MQ's non-persistent message.

**Supply chain:** `kafkajs` is pure JS with no native dependencies — low friction. **Ask whether
Confluent Schema Registry + Avro is mandated**; if so that is another service to reach, mirror
and govern, plus a schema-evolution workstream nobody has costed.

#### 9.1.4 Answers to be prepared for that are not on the list

- **File drop (SFTP / NFS / S3)** — batch, and more common for downstream *reporting* consumers
  than people admit. If a consumer is batch, this pipeline is over-built for that consumer
  (though not for the SWIFT-response path). Idempotency becomes file naming plus control totals.
- **Shared database "interface table"** — legacy but alive, and ironically the **easiest**
  idempotency story: a unique index on the event ID does the whole job, atomically.
- **ISO 20022 payload over any of the above** — the message standard is orthogonal to the
  transport, but the two questions usually arrive fused. Separate them deliberately.

#### 9.1.5 What follows regardless of the answer

Two rules, promoted to decisions because they must not be left to whoever writes the adapter:
**E-20** (delete only after a durable ack) and **E-21** (adapter behind a stable interface).

E-21 matters more than it first looks. **EQ-2 may well resolve to several answers at once** —
MQ for the payments engine, HTTP for a reconciliation service, file drop for reporting. Fan-out
to multiple queues (E-16) already supports that topologically; the adapter interface is what
stops it becoming three bespoke codebases with three different bugs.

---

## 10. What the new project's `CLAUDE.md` gains from this

| Section | Purpose |
|---|---|
| **Event-pipeline guarantees** | E-1..E-4 plus **E-17** as hard rules: chain is the record, cursor advances only post-ACK, the event ID formula, and the explicit warning that SQS FIFO's "exactly-once" is a 5-minute window and never the idempotency mechanism. |
| **Reconciliation runbook** | The E-12 job, its alarm thresholds, and the cursor-rewind procedure (the ultimate backstop) — a runbook, per the continuous-documentation mandate. |
| **Nonce-safety rule** | Single-writer nonce management (E-8), in the same spirit as the H1 validator rolling-upgrade rule: a structural constraint, not discipline. |
| **Contract idempotency rule** | E-9 — the contract, not the pipeline, is where duplicate business events are stopped. |
| **Transport-portability rule** | E-5 + §6.2 — no transport-specific concepts in the envelope schema or consumer business logic, so option 2 stays a decision rather than a rebuild. |
| **Adapter contract** | §9.1 + E-20/E-21 — the four questions to settle with any receiving system, the per-protocol durability traps (MQ persistence, HTTP 202, Kafka `acks=1`), and the delete-only-after-durable-ack rule. This is the boundary where our at-least-once pipeline meets someone else's system. |
| **Endpoint + IP budget delta** | §7 rows folded into the redesign notes' §3.2 and §5.3 tables. |

---

## 11. Sources

- [Amazon SQS FIFO queues](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues.html)
- [SQS FIFO exactly-once processing & deduplication](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues-exactly-once-processing.html)
- [Amazon SNS FIFO topics](https://docs.aws.amazon.com/sns/latest/dg/sns-fifo-topics.html)
- [SNS message delivery — supported subscription protocols](https://docs.aws.amazon.com/sns/latest/dg/sns-event-destinations.html)
- [SQS dead-letter queues & redrive policy](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html)
- [Amazon MSK](https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html) (option 2)
- [IBM MQ — message properties](https://www.ibm.com/docs/en/ibm-mq/latest?topic=applications-message-properties) (§9.1.1)
- [IBM MQ — message persistence](https://www.ibm.com/docs/en/ibm-mq/latest?topic=mechanisms-message-persistence) (§9.1.1)
- [IBM MQ — AMQP 1.0 applications](https://www.ibm.com/docs/en/ibm-mq/latest?topic=developing-amqp-applications) (§9.1.1, avoids the native client)
- [IETF draft — The Idempotency-Key HTTP Header Field](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/) (§9.1.2)
- [Apache Kafka — producer `acks` / `min.insync.replicas`](https://kafka.apache.org/documentation/#producerconfigs_acks) (§9.1.3)
- [AWS PrivateLink — VPC endpoints for SQS / SNS](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-internetwork-traffic-privacy.html)
- [Hyperledger Besu — QBFT consensus (immediate finality)](https://besu.hyperledger.org/private-networks/how-to/configure/consensus/qbft)
- [Hyperledger Besu — `eth_getLogs` / `--rpc-max-logs-range`](https://besu.hyperledger.org/public-networks/reference/api)
- `CLOUD_TEAM_REDESIGN_NOTES.md` (this repo) — CT-1..CT-4, D-1..D-9, Q-1..Q-5
