# FIPS 140-2 Level 3 Key Management — Validator / Consensus Keys

**Options analysis prepared for compliance & external audit review**

| | |
|---|---|
| **System** | Permissioned Hyperledger Besu (QBFT consensus) blockchain network on AWS EKS |
| **Deployment** | Single AWS region (`af-south-1`, Cape Town); fully private (no public endpoints) |
| **Scope of this document** | The **validator, bootnode, and node-identity private keys** only. Application / transaction-signing keys are explicitly out of scope here. |
| **Requirement under assessment** | Private keys must be **managed in hardware validated to FIPS 140-2 Level 3 (or higher)**. |
| **Date** | 2026-07-03 |
| **Version / status** | 1.1 — *For auditor review. The §9 compliance interpretation is still requested; separately, the §10.2 baseline controls (Option 1) have now been implemented — see §11.* |

---

## 1. Executive summary

The system uses a set of **validator/node private keys** (one per blockchain node). Each validator key does two jobs: it **signs consensus messages and block seals** (the act that gives a validator its authority), and it is the node's **network identity** for peer-to-peer communication.

We assessed whether these keys can be brought under FIPS 140-2 Level 3 (or higher) hardware. The finding is that the choice reduces to **one question of interpretation**, not one of technology:

> **Does the requirement mean the key must be *generated inside, and never leave,* certified hardware — with the cryptographic signing performed *inside* that hardware? Or is it satisfied by keys that are *encrypted at rest* under FIPS-Level-3-validated hardware, combined with strong runtime controls?**

- If **encryption-at-rest under FIPS-L3 hardware + strong controls** is acceptable, the requirement can be met **cheaply, with no change to the blockchain's behaviour**, using **AWS KMS + AWS Secrets Manager** (Option 1 below). This is a small, low-risk change.
- If the key must be **generated in and never leave** the hardware (signing performed *in* the module — the strict reading), then only **AWS CloudHSM** with a hardware-security-module plugin for Besu can satisfy it (Option 2 below). This is a substantial project with a significant, recurring cost (roughly **+$2,300–3,500 per month**) and introduces the hardware module into the live consensus path.

Both options are achievable **within `af-south-1`** — no region change is required. Section 9 states the single decision we ask compliance/audit to adjudicate, and the consequences of each answer.

---

## 2. Background — what these keys are and why they matter

The network reaches agreement using **QBFT** (a Byzantine-fault-tolerant consensus protocol) run by **4 validator nodes**. To propose and finalise a block, a validator **cryptographically signs** consensus messages with its private key. That signature *is* the validator's authority: possession of a validator key is the ability to participate in producing blocks. Compromise of a validator key is therefore the most security-sensitive key-compromise scenario in the system.

Each key is an **secp256k1** elliptic-curve private key (the same curve family used by Ethereum and Bitcoin). In Besu, one key per node serves **three** functions simultaneously:

1. **Consensus signing** — signing QBFT block seals and round-change/commit messages (validators only).
2. **Peer-to-peer identity & session security** — the node's `enode` identity, and the elliptic-curve key agreement (ECDH) used to encrypt peer-to-peer traffic.
3. **Peer discovery** — signing discovery-protocol messages.

Point (2) matters for this analysis: because the key is also used for **key agreement (ECDH)**, not only signing, any hardware-backed solution must support *both* operations on the secp256k1 curve — a constraint that rules out some options (see §5).

### 2.1 Key-sensitivity tiers (informational)

Although all three key types are in scope, they do not carry equal risk. This may be useful for a risk-based assessment:

| Key type | If compromised, an attacker can… | Sensitivity |
|---|---|---|
| **Validator key** | Participate in / disrupt consensus; forge a validator's signatures | **Highest** |
| **Bootnode key** | Impersonate a discovery seed node | Medium |
| **RPC / other node key** | Impersonate a non-validating node's network identity | Lower |

The remainder of this document treats all three uniformly (as the requirement is scoped), but the controls and cost apply most compellingly to the **validator** keys.

---

## 3. How these keys are handled today (the baseline)

Understanding the current state is important, because part of the requirement is **already satisfied today**, and the analysis is really about closing a specific, narrow gap.

Today:

1. Each node key is stored as a secret in **AWS Secrets Manager**.
2. Secrets Manager **encrypts every secret at rest using AWS KMS**, whose hardware modules are **FIPS 140-3 Level 3 validated** (see §4). Today this uses the *AWS-managed* KMS key (`aws/secretsmanager`) rather than a key we control.
3. At pod start, the key is delivered into the running container by the **Secrets Store CSI driver**, which mounts it in an **in-memory (tmpfs) volume** — i.e. the key is **not written to disk** on the node.
4. Besu reads the key from that in-memory file (`--node-private-key-file`) and holds it in process memory to sign.

**What this means in FIPS terms:**

- **At rest:** the key is *already* protected by FIPS 140-3 Level 3 hardware (KMS), because that is how Secrets Manager encrypts. The gap here is one of **control and auditability**, not of FIPS level: the encryption key is AWS-managed, without a dedicated key policy, access boundary, or per-access audit trail that we own.
- **In use (signing):** the key exists **in plaintext, in the node's process memory**, outside any hardware module, for as long as the node is running. This is the crux of the whole assessment (§5, §6).

---

## 4. What "FIPS 140-2 Level 3" means here, and the one distinction that governs everything

**FIPS 140-2 / 140-3** is the US government standard (administered by NIST's Cryptographic Module Validation Program, "CMVP") for the security of cryptographic hardware/software modules. **Level 3** adds physical tamper-resistance/response and identity-based operator authentication over Level 2. **FIPS 140-3** is the successor to 140-2; a **140-3 Level 3** module therefore satisfies a "**140-2 Level 3 or higher**" requirement.

The single most important distinction for this decision — and the one we ask auditors to focus on — is the difference between two things that both loosely get called "using an HSM":

> **(A) Encryption *at rest* by certified hardware.** The private key is *stored* encrypted, and the encrypting key lives in a FIPS-L3 module. But to *use* the key, the plaintext is brought **out** of the module (here, into the application's memory) to perform the signature.
>
> **(B) Key custody *in use* — signing *inside* certified hardware.** The private key is **generated inside** the module and **never leaves it**. To sign, the application sends the *data* into the module; the module returns a *signature*. The plaintext key never exists anywhere outside the certified boundary.

**A plain-language analogy.** Think of the HSM as a bank vault.
- **Option A (at rest):** the key is kept in the vault overnight, but each morning a clerk takes it out to a desk, uses it, and returns it. While in use, the key is on the desk — outside the vault.
- **Option B (in hardware):** the vault has a slot. You post the document in; it is signed *inside* the vault and posted back out. The key never leaves the vault, ever.

Every option below is ultimately classified by which of these two it provides for the **signing** operation. The technology choices are a consequence of that one distinction.

---

## 5. The governing technical constraint (why the software cannot simply "point at KMS")

A natural first instinct is: *"store the key in AWS KMS and have the blockchain software sign through it."* For these particular keys, **that is not possible**, for a concrete software reason:

- Besu performs consensus (QBFT) signing **inside its own process**, using a key it reads from a local file. It has **no facility to delegate node-key signing to a remote service** such as AWS KMS. (This is different from *transaction/account* signing — out of scope here — which *can* be delegated to KMS. The **node/validator** key cannot.)
- Besu *does* provide a **hardware-module plugin interface** (its `--security-module` option). The officially supported plugin backs the node key with a **PKCS#11 hardware security module** — in AWS, that means **AWS CloudHSM**. This is the only supported way to keep a Besu **node** key inside hardware and sign inside hardware.
- AWS KMS is **not** a PKCS#11 module and cannot be used through that plugin. Additionally, the node key must perform **ECDH key agreement** for peer-to-peer session encryption (§2), which AWS KMS does not offer for the secp256k1 curve — a second, independent reason KMS cannot host the *node* key.

**Consequence:** for validator/node keys, the "sign inside certified hardware" outcome (distinction B) is achievable **only via AWS CloudHSM**, never via AWS KMS. AWS KMS can only ever provide the "encrypted at rest" outcome (distinction A) for these keys. This single fact shapes the options below.

*(For completeness: one could in principle write a bespoke Besu security-module plugin that calls KMS. It would require custom software development with no vendor support, would still place a network call in the live consensus path, and would still fail the ECDH requirement above. We do not consider it viable and do not recommend it.)*

---

## 6. The options

### Option 0 — Current state (baseline)

- **What it is:** as described in §3.
- **At-rest custody:** FIPS 140-3 L3 (KMS), but under an AWS-managed key we do not control or audit.
- **Signing:** in application memory (plaintext, outside hardware).
- **Cost:** none additional.
- **Verdict:** does **not** meet a strict reading of the requirement; only partially meets a lenient (at-rest) reading, because the encryption key is uncontrolled.

### Option 1 — AWS KMS + AWS Secrets Manager (customer-managed envelope encryption)

- **What it is:** we generate each node key, encrypt it under a **customer-managed KMS key (CMK)** — which resides in FIPS 140-3 Level 3 hardware — and store the ciphertext in Secrets Manager. At pod start, the container calls KMS to **decrypt inside the KMS hardware**, and the plaintext is placed only into an **in-memory** location for Besu to read.
- **How it works, step by step:**
  1. A customer-managed KMS key (CMK) is created, with a key policy that permits decryption **only** by the validator pods' specific IAM role.
  2. Each node key is stored encrypted under that CMK.
  3. On startup, the node's identity (via IAM Roles for Service Accounts, "IRSA") authorises a single `Decrypt` call; the decryption is performed **inside the KMS FIPS-L3 module**.
  4. The plaintext key is written **only to an in-memory volume** (never to disk) and read by Besu.
  5. **Every decryption is logged in AWS CloudTrail**, giving a complete, tamper-evident access record.
- **At-rest custody:** FIPS 140-3 L3 (KMS), now under a **controlled, audited, access-restricted** key — CMVP certificate **#4884**.
- **Signing:** still in application memory (plaintext, outside hardware) — this option does **not** change how Besu signs.
- **Cost:** negligible — on the order of **~$1 per key per month** for the CMK, plus trivial request charges (one decrypt per pod start).
- **Operational impact:** minimal; no change to consensus behaviour, no added latency, no new always-on infrastructure, no hardware cluster to operate.
- **Verdict:** **Fully meets the "encryption at rest under FIPS-L3 hardware + strong controls" reading. Does not meet the strict "key never leaves hardware / signs in hardware" reading.**

A note of transparency for auditors: because Secrets Manager already encrypts with KMS FIPS-L3 hardware, the *FIPS level* of the at-rest protection is not raised by this change. What Option 1 adds is **control, isolation, restricted access, key rotation, and a dedicated audit trail** — the governance around the key — not a higher certification tier. We state this plainly rather than imply Option 1 is more than it is.

### Option 2 — AWS CloudHSM + Besu hardware-security-module plugin

- **What it is:** a **single-tenant, dedicated** hardware security module cluster (AWS CloudHSM). Each node key is **generated inside the HSM and never leaves it**; Besu is configured (via its `--security-module` plugin) to perform consensus signing and key agreement **inside the HSM**.
- **At-rest custody:** FIPS 140-3 L3, single-tenant — CMVP certificate **#4703** (current `hsm2m.medium` instance type).
- **Signing:** **inside the hardware module** — the plaintext key never exists outside the certified boundary. This is the only option that satisfies distinction (B).
- **Cost:** substantial and recurring. CloudHSM is billed per hardware module per hour (~$1.60/HSM/hour in typical regions). A resilient deployment requires **at least two HSMs across Availability Zones**; three for full three-AZ resilience. This is approximately **+$2,300/month (2 HSMs)** to **+$3,500/month (3 HSMs)** — which, against the network's right-sized run-rate of roughly $1,240/month, **doubles to triples the total infrastructure bill.**
- **Operational impact — material:**
  - The HSM becomes a **dependency in the live consensus path**: every block seal and every peer handshake becomes a call into the HSM. At the current 5-second block cadence this is expected to be tolerable, but it **must be load-tested before adoption**, and an HSM-cluster outage could stall block production.
  - A CloudHSM cluster is **operational infrastructure to run**: cluster provisioning, HSM user/quorum management, encrypted backups, and AZ-spread for resilience.
  - The Besu HSM plugin must be **validated against the exact Besu version in use** before adoption.
  - **Verify** that the current FIPS-140-3-L3 CloudHSM instance type (`hsm2m.medium`) is orderable in `af-south-1` before committing (the older `hsm1.medium` type is being retired — see §8).
- **Verdict:** **Meets the strict "key never leaves hardware / signs in hardware" reading.** It is the only option that does.

---

## 7. Side-by-side comparison

| Criterion | Option 0 — Today | Option 1 — KMS + Secrets Manager | Option 2 — CloudHSM + plugin |
|---|---|---|---|
| Encrypted **at rest** by FIPS-L3 hardware | Yes (uncontrolled key) | **Yes** (controlled, audited; cert #4884) | **Yes** (cert #4703) |
| Key **generated in & never leaves** hardware | No | **No** | **Yes** |
| **Signing performed inside** hardware | No | **No** | **Yes** |
| Dedicated **audit trail** of key access | No | **Yes** (CloudTrail per-decrypt) | Yes (HSM audit log) |
| Key access restricted to validator identity | Partial | **Yes** (IAM + key policy) | Yes (HSM users) |
| Single-tenant / dedicated hardware | No (multi-tenant) | No (multi-tenant) | **Yes** |
| Impact on consensus behaviour / latency | None | **None** | HSM call on the consensus path |
| New always-on infrastructure to operate | None | None | **HSM cluster (≥2 modules)** |
| Approx. incremental cost | $0 | **~$1 / key / month** | **~$2,300–3,500 / month** |
| Satisfies **lenient** (at-rest) reading | Partially | **Yes** | Yes |
| Satisfies **strict** (in-hardware) reading | No | **No** | **Yes** |

---

## 8. Facts an auditor can verify independently

Every material claim in this document can be checked against primary sources:

- **AWS KMS is FIPS 140-3 Level 3 validated, in all commercial AWS regions (including `af-south-1`).** CMVP certificate **#4884**. Multi-tenant (shared) hardware.
  - AWS: <https://aws.amazon.com/blogs/security/aws-kms-now-fips-140-2-level-3-what-does-this-mean-for-you/>
  - AWS KMS FAQ (regional coverage): <https://aws.amazon.com/kms/faqs/>
  - NIST CMVP certificate #4884: <https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4884>
- **AWS CloudHSM (`hsm2m.medium`) is FIPS 140-3 Level 3 validated; single-tenant; supports the secp256k1 curve used here.** CMVP certificate **#4703**. The older `hsm1.medium` (FIPS 140-2 Level 3, cert #4218) is being retired (moves to the CMVP historical list on 2026-01-04; automatic migration to `hsm2m.medium` begins 2026-01-20) — new designs should use `hsm2m.medium`.
  - CloudHSM FIPS validation: <https://docs.aws.amazon.com/cloudhsm/latest/userguide/fips-validation.html>
  - Supported key types (secp256k1 listed): <https://docs.aws.amazon.com/cloudhsm/latest/userguide/pkcs11-key-types.html>
  - NIST CMVP certificate #4703: <https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4703>
- **Besu backs the node key in hardware only via a PKCS#11 security-module plugin (i.e. CloudHSM), and cannot delegate node-key signing to AWS KMS.**
  - Besu node-keys / security module documentation: <https://docs.besu-eth.org/public-networks/concepts/node-keys>
  - Besu HSM plugin (PKCS#11 / AWS CloudHSM; covers QBFT/IBFT consensus signing): <https://github.com/besu-eth/besu-hsm-plugin>
- **AWS Secrets Manager encrypts secrets at rest using AWS KMS** (the basis for the "already FIPS-L3 at rest today" statement in §3):
  - <https://docs.aws.amazon.com/secretsmanager/latest/userguide/security-encryption.html>

*Regional caveat to verify with AWS:* the FIPS-validation of the **key hardware** is global and applies in `af-south-1`. Separately, availability of a FIPS-validated **API endpoint for data-in-transit** in `af-south-1` is stated inconsistently across AWS documentation. This only matters if the requirement extends to FIPS-validated encryption *in transit* (a different control from key custody); if so, it should be confirmed directly with AWS for `af-south-1`.

---

## 9. The decision we ask compliance / audit to make

The technology follows directly from **one interpretation**. We ask for a written determination on the following:

> **For the validator / bootnode / node private keys, does "managed in FIPS 140-2 Level 3 (or higher) hardware" require:**
>
> **(A)** the key to be **generated in and never leave** a FIPS-L3 hardware module, with signing performed **inside** the module; **or**
>
> **(B)** the key to be **encrypted at rest** under FIPS-L3-validated hardware, under a controlled and audited key, with strong runtime controls governing its use?**

**If the determination is (B):** we recommend **Option 1 (AWS KMS + Secrets Manager)**. It meets the requirement, costs approximately $1 per key per month, adds no risk to consensus, and requires no new infrastructure. We would implement it with the following **compensating controls**, offered for audit evaluation:

- A dedicated **customer-managed KMS key (CMK)** whose key policy permits decryption **only** by the validator pods' IAM role.
- Plaintext key material delivered **only into memory** (never written to node disk).
- **Least-privilege** access via IRSA plus a scoped KMS grant.
- **CloudTrail** logging and alerting on every decryption event.
- A defined **key-rotation** procedure.
- Remediation of the legacy certificate-authority key so that no long-lived private key is stored in Terraform state.

**If the determination is (A):** only **Option 2 (AWS CloudHSM)** qualifies. This is a funded project decision: it approximately doubles-to-triples the monthly infrastructure cost, introduces the HSM into the live consensus path (requiring load-testing), and adds an HSM cluster to operate. We would proceed only with explicit budget approval and after validating the Besu HSM plugin and `af-south-1` availability of the required HSM type.

---

## 10. Recommendation

1. **Obtain the §9 determination first.** The entire cost and architecture difference hinges on that single interpretation; it should not be assumed by the engineering team.
2. **Regardless of the outcome, adopt the Option 1 controls as a baseline improvement** (customer-managed CMK, memory-only delivery, restricted access, CloudTrail audit, CA-key remediation). These are low-cost, strictly improve the current posture, and are prerequisites even under a lenient reading.
3. **Reserve Option 2 (CloudHSM) for the case where a strict, in-hardware-signing reading is mandated in writing**, given its recurring cost and its introduction of the HSM into the consensus path.

---

## 11. Implementation status (2026-07-05)

Per recommendation §10.2 — *"regardless of the outcome, adopt the Option 1 controls as a baseline
improvement"* — the **Option 1 (AWS KMS + Secrets Manager) controls have been implemented AND
PROD-VERIFIED (2026-07-05**, deploy-test 2026-07-05, log in the frozen `besu-aws` reference repo: pods decrypted
CMK-encrypted node keys via CSI, and CloudTrail recorded 18 Decrypt **management** events — F31
removed the invalid data-event selector). This is a strict improvement to the
current posture and is a prerequisite under either reading; it is **not** a substitute for the §9
determination. If compliance rules **(A)** (strict, in-hardware signing), Option 2 (CloudHSM) remains
required *in addition*.

What was implemented (all gated by a single switch, `enable_node_key_cmk`):

- A **dedicated customer-managed KMS key (CMK)** with **annual key rotation**, whose key policy grants
  decryption to **only** the Besu pod IAM role (read) and the key-provisioning (genesis) role
  (read + generate) — with account-root retained solely for administration to prevent lockout.
- The **validator / bootnode / node-identity key secrets — and the certificate-authority private key —
  are now encrypted under that CMK** at rest, in place of the AWS-managed key.
- **Least-privilege access** via IRSA plus a **scoped KMS grant** on those two roles only.
- **CloudTrail logging of every decryption** of these keys. (KMS `Decrypt`/`GenerateDataKey` are
  CloudTrail *management* events — logged by the base trail under event source `kms.amazonaws.com`;
  they are not "data events", so no advanced event selector is used.) This gives the per-access
  audit trail described in §6/Option 1.
- **Plaintext delivered only into memory** (unchanged — the Secrets Store CSI driver already uses an
  in-memory tmpfs mount; no key is written to disk).
- **Certificate-authority key remediation:** the Secrets Manager copy is now CMK-encrypted; to fully
  remove any long-lived private key from Terraform state, the deployment can additionally select
  `ca_mode="aws"` (AWS Private CA), which keeps the CA key inside the PCA HSM and never exports it.

**Retrievability (an inherent property of Option 1, stated for the record).** Because Option 1 is
*at-rest* encryption, the key remains **retrievable in plaintext by authorized principals** — the
validator-pod IAM role, the key-provisioning role, or an account administrator — with **every retrieval
recorded in CloudTrail** (the Secrets Manager read plus the KMS decryption). This is by design: the
blockchain software needs the plaintext to sign. It is precisely the property that **Option 2
(CloudHSM) removes** — there the key is *non-exportable* and no operator can extract it. If the
requirement is "no human may ever retrieve the key material," Option 1 does not meet it and Option 2 is
required. (The same retrievability is what lets an operator take an out-of-band **backup** of a
key that was generated in-cluster.)

Still outstanding: (1) the §9 compliance determination itself; (2) a documented key-rotation
*operational* procedure to accompany the automated rotation. (The production deploy-test confirming
pods decrypt via the CMK and the audit events appear was completed 2026-07-05 — it also found and
fixed **F31**: `AWS::KMS::Key` is not a data-event resource type; KMS decrypts are CloudTrail
management events, already captured by the base trail.)

---

## Appendix — glossary for reviewers

| Term | Meaning |
|---|---|
| **Validator / node key** | The secp256k1 private key that gives a blockchain node its consensus authority (for validators) and its network identity. The subject of this document. |
| **QBFT** | The Byzantine-fault-tolerant consensus protocol the network runs; validators sign QBFT messages to produce blocks. |
| **secp256k1** | The elliptic-curve used for these keys (also used by Ethereum/Bitcoin). |
| **HSM (Hardware Security Module)** | Tamper-resistant hardware that generates, stores, and uses cryptographic keys without exposing them. |
| **FIPS 140-2 / 140-3, Level 3** | NIST security standard for cryptographic modules; Level 3 adds physical tamper-response and identity-based operator authentication. 140-3 supersedes 140-2. |
| **CMVP** | NIST's Cryptographic Module Validation Program, which issues the validation certificates cited here. |
| **AWS KMS** | AWS Key Management Service — a **multi-tenant** managed key service backed by FIPS-140-3-L3 hardware. Can encrypt keys at rest; **cannot** host the Besu node key for in-hardware signing. |
| **AWS CloudHSM** | AWS-managed **single-tenant** dedicated HSM. Can host the Besu node key and sign inside the hardware. |
| **CMK (customer-managed key)** | A KMS key that the customer creates and controls (key policy, rotation, audit), as opposed to an AWS-managed key. |
| **Envelope encryption** | Encrypting data (here, a node key) under a key that is itself protected inside an HSM. |
| **Secrets Manager** | AWS service that stores secrets, encrypting them at rest with KMS. |
| **CSI driver / tmpfs** | The mechanism that delivers a secret into a running container; here it uses an **in-memory** (tmpfs) volume, so the key is not written to disk. |
| **IRSA** | "IAM Roles for Service Accounts" — the mechanism binding a specific AWS permission set to specific Kubernetes workloads. |
| **CloudTrail** | The AWS audit log that records API calls, including each key decryption. |
| **devp2p / ECDH** | The peer-to-peer protocol and the elliptic-curve key-agreement operation the node key also performs (relevant because it constrains which hardware options are viable). |

---

*This document is an engineering options analysis prepared to support a compliance determination. It does not itself assert regulatory compliance; the FIPS-validation certificates and AWS/Besu documentation cited in §8 are the authoritative sources.*
