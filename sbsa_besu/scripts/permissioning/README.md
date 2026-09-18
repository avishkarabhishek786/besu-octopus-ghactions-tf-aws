# Account permissioning — operator runbook (`scripts/permissioning/`)

File-based account (transaction-sender) permissioning for the Besu QBFT network
(**backlog C6**). These scripts manage **who is allowed to originate transactions**
once `account_permissioning_mode="local"` is enabled. They are the day-2 tooling
for onboarding/offboarding SWIFT and dApp signer accounts **without re-genesis**.

> Node (P2P) permissioning is a *different*, always-on control and is **not**
> managed here — see `docs/manual-deployment-guide.md` §8 and
> `docs/explained/02-blockchain-layer.md` §1.2.

---

## When does any of this apply?

Only when **`account_permissioning_mode="local"`**. With the default `"off"`:

- no `besu-account-allowlist` ConfigMap exists, nodes emit no account flags, and
  **any funded account may transact** — these scripts will refuse to run
  (`ConfigMap 'besu-account-allowlist' not found`).

To turn it on, seed the allowlist in the env tfvars **before** the chain apply
(deny-by-default — an empty allowlist denies every sender, and a render-time
preflight blocks that):

```hcl
account_permissioning_mode  = "local"
permissioning_admin_account = "0x<admin>"               # required; first authorized sender
initial_account_allowlist   = ["0x<swift>", "0x<app>"]  # more senders; also genesis-funded
```

Everything below is for changes **after** that initial deploy.

---

## Mental model (read once)

- **Single source of truth = the `besu-account-allowlist` ConfigMap** (Model B).
  It holds `accounts-allowlist=["0x…", …]` and is mounted **read-only** into every
  enforcing node at `/config/perm-accounts/permissions_accounts.toml`.
- **Deny-by-default, sender-only.** Only listed addresses may be the `from` of a
  transaction. Recipients (`to`) are **not** gated — so *funding* a new address is
  independent of *allowlisting* it (either order).
- **Node-local, not chain state.** The allowlist is per-node config, so a change
  must be applied to **every enforcing node** (all validators + every RPC pool).
  The scripts do that fan-out for you.
- **Two truths to keep in sync.** The *live* ConfigMap (what these scripts patch)
  and the *durable* tfvars (`initial_account_allowlist`). A runtime patch is
  **reverted on the next `terraform apply`/`helm upgrade`** — so persist every
  onboarding to tfvars too (the auditable path).
- **Zero-gas funding caveat (F20).** On this free-gas chain a **zero-balance
  sender's tx is never mined**. An allowlisted account still can't transact until
  it holds a balance — see [Funding](#funding-an-account).

---

## Prerequisites

- Run **from the in-VPC runner** (the private EKS endpoint isn't reachable from a
  laptop), at the repo root, after
  `aws eks update-kubeconfig --name <cluster> --region <region>`.
- Tools: `kubectl`, `jq` (all scripts); `cast` (Foundry) for `fund-account.sh`
  (`curl -L https://foundry.paradigm.xyz | bash && foundryup`); `curl` for
  `PROPAGATE=hot`.

---

## The scripts

| Script | Purpose | Typical use |
|---|---|---|
| `add-account.sh <0xaddr…>` | Add sender(s) to the allowlist + propagate | Onboard a new SWIFT/dApp signer |
| `remove-account.sh <0xaddr…>` | Revoke sender(s) + propagate (refuses to empty) | Offboard a signer |
| `list-accounts.sh [--live]` | Show the allowlist (and each pod's live view) | Audit / verify a change landed |
| `reload-permissions.sh` | Propagate the **current** ConfigMap to running pods | After a `terraform apply` changed the allowlist |
| `fund-account.sh <0xaddr…>` | Send native value from a faucet account | Give a new sender a balance (F20) |

### Propagation modes (shared by add / remove / reload)

A ConfigMap change does **not** by itself update a running node's in-memory
allowlist. `PROPAGATE` controls how the change reaches the pods:

| `PROPAGATE` | What happens | When to use |
|---|---|---|
| `restart` *(default)* | Rolling restart of every enforcing StatefulSet; each pod re-reads the ConfigMap on boot. **Validators go one-at-a-time under a QBFT quorum-advancing gate**, then a `/data` read-back verifies each validator's enforced list. | Always safe; needs nothing extra |
| `hot` | **Reconciles** each validator's in-memory allowlist to the patched ConfigMap via `perm_add/removeAccountsFromAllowlist` on the **internal ops listener**, then reads back `perm_getAccountsAllowlist` and **fails loudly on mismatch**; + a restart of the RPC pools. No validator bounce. | Faster; requires `opsRpc.enabled=true` (exposes `PERM` ClusterIP-only) |
| `none` | Patch the ConfigMap only; propagate later with `reload-permissions.sh`. | Batching changes, or when you'll `terraform apply` then reload |

Other env knobs: `NAMESPACE` (default `besu`), `SETTLE_SECONDS` (quorum-gate
observation window, default 15), `ROLLOUT_TIMEOUT` (default `300s`), `OPS_PORT`
(default `8545`). (`CM_SYNC_WAIT` is obsolete since the H3 fix — `hot` now sets the
in-memory allowlist directly via `perm_*` instead of waiting for a ConfigMap→mount sync.)

> **H3 fix (2026-07-06):** `hot` previously called `perm_reloadPermissionsFromFile`, which
> re-read the *frozen* `/data/permissions_accounts.toml` boot-copy (the main besu container
> never mounts the ConfigMap) → a **silent no-op**: a revocation reported `Success` while the
> sender kept transacting. `hot` now reconciles the in-memory allowlist and verifies via
> `perm_getAccountsAllowlist`. Always confirm a revocation with `list-accounts.sh --live`.

---

## Common workflows

### 1) Onboard a new authorized sender (the full flow)

```bash
# a) allow it to transact (patches the ConfigMap, then propagates)
scripts/permissioning/add-account.sh 0x<newSender>

# b) give it a balance so it can actually originate tx on the zero-gas chain (F20)
FAUCET_KEY_SECRET=besu-faucet-key PF_STATEFULSET=besu-explorer-rpc-1 \
  AMOUNT=1ether scripts/permissioning/fund-account.sh 0x<newSender>

# c) verify every enforcing pod sees it, and the balance landed
scripts/permissioning/list-accounts.sh --live

# d) PERSIST — add 0x<newSender> to initial_account_allowlist in the env tfvars
#    and commit, so the next `terraform apply` doesn't revert the ConfigMap.
```

Steps (a) and (b) are independent (recipient isn't gated), so order doesn't
matter. Do **not** skip (d) — the runtime patch is not durable on its own.

### 2) Revoke a sender

```bash
scripts/permissioning/remove-account.sh 0x<sender>   # refuses to remove the LAST entry
# then delete it from initial_account_allowlist in tfvars and commit.
```

Revocation stops *future* transactions from that sender; it does not touch any
balance it holds. To fully retire it, revoke **and** (optionally) sweep its funds
back to a treasury with a tx signed by that account.

### 3) You changed the allowlist in tfvars and applied

`terraform apply` regenerates the ConfigMap but does **not** restart the
StatefulSets, so running pods keep the old in-memory list. Propagate:

```bash
scripts/permissioning/reload-permissions.sh            # default: rolling restart
PROPAGATE=hot scripts/permissioning/reload-permissions.sh   # if the ops listener is on
```

### 4) Audit the live state

```bash
scripts/permissioning/list-accounts.sh          # the ConfigMap (source of truth)
scripts/permissioning/list-accounts.sh --live   # + each pod's mounted view (spot a lagging node)
```

---

## Funding an account

Genesis funding (`genesis_funded_accounts` / `initial_account_allowlist`) fires
**once, at chain creation** — it cannot reach an account added later. The only
post-genesis way to fund an address is an **on-chain transfer from an account that
is both allowlisted and funded** (the admin, or any `initial_account_allowlist`
member — each got a large genesis balance). That's what `fund-account.sh` does.

```bash
# faucet key from Secrets Manager, endpoint via a port-forward to a plain-HTTP pool
FAUCET_KEY_SECRET=besu-faucet-key PF_STATEFULSET=besu-explorer-rpc-1 \
  AMOUNT=5ether scripts/permissioning/fund-account.sh 0x<new> [0x<new2> …]

# or a raw key against an endpoint you can already reach
FAUCET_KEY=0x<faucetPrivKey> RPC_URL=http://127.0.0.1:8545 \
  scripts/permissioning/fund-account.sh 0x<new>
```

Notes:
- The transfer is **free** (gasPrice 0); the faucet only needs balance to cover
  the `AMOUNT`. Genesis balances are astronomically large, so that's never a
  constraint. The token is valueless on this closed chain — fund generously.
- **Endpoint:** the SWIFT and app RPC pools require mTLS / JWT, so the simplest
  internal path is `PF_STATEFULSET=<a plain-HTTP pool>` — the explorer-rpc pool
  (if Blockscout is deployed) or an **enabled** validator ops listener. Otherwise
  pass an `RPC_URL` you can reach with the right auth.
- **Who holds the key:** funding needs the **faucet's private key**. For routine
  top-ups, seed a dedicated **treasury** address into `initial_account_allowlist`
  at genesis (allowlisted + funded) and use it as the faucet, rather than the
  admin key. Key custody is the subject of the FIPS/KMS work (backlog **C12**).

---

## Security notes (state these for auditors)

- **`PERM` is never on an external edge.** The `perm_*` mutators are exposed
  **only** on the ClusterIP-only, port-forward-only validator ops listener — never
  on the SWIFT or app RPC pools. Onboarding is an operator action from inside the
  VPC.
- **Enforcement is node-local, not consensus/Byzantine.** Each node checks the
  sender against its own file; a block that already contains a non-allowlisted
  sender is not rejected by peers. It holds because we own all validators and they
  carry an identical list — a *cooperative* control, not Byzantine-resistant.
  There is no stronger option on Besu 26.6.1 (the consensus-enforced on-chain
  variant was removed in 25.6.0 — F17). Full rationale:
  `docs/explained/02-blockchain-layer.md` §2.5.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ConfigMap 'besu-account-allowlist' not found` | Account permissioning is `off`. Enable `account_permissioning_mode="local"` (seeded) and apply. |
| A newly-added sender's tx is rejected | It isn't funded — run `fund-account.sh` (F20). Or a pod hasn't propagated yet — `list-accounts.sh --live` and re-`reload-permissions.sh`. |
| `PROPAGATE=hot` fails on a validator | The ops listener isn't enabled. Set `opsRpc.enabled=true` (exposes `PERM` internally) or use the default `restart`. |
| Change disappeared after a deploy | You skipped persisting to tfvars — the ConfigMap was reverted on `terraform apply`. Add the address to `initial_account_allowlist` and commit. |
| `remove-account.sh` refuses | You'd empty the allowlist (denies all senders). Disable account permissioning via tfvars instead of emptying it. |
| `fund-account.sh`: faucet has ZERO balance | The faucet address isn't a genesis-funded allowlist member. Use the admin or an `initial_account_allowlist` account. |
