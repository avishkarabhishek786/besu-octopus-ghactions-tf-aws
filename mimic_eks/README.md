# `mimic_eks` — the cloud team's shared EKS cluster, impersonated

Throwaway fixture for **CT-5** (D-32): the cloud team provides a shared EKS cluster and
allots us a namespace. This project pretends to be them, so the platform can be built and
— more importantly — **so the platform's checks can be proven to fail.**

- Operating brief and the full rule set: **[CLAUDE.md](CLAUDE.md)**
- Design record: `../sbsa_besu/docs/CLOUD_TEAM_REDESIGN_NOTES.md` §12
- The requirements reproduced: `../sbsa_besu/docs/NETWORK_REQUIREMENTS_CLOUD_TEAM.md` §9.3

**The default profile is `hostile`, and that is deliberate.** It produces a cluster that
breaks every gate the platform has: a public API endpoint, a Kubernetes version above the
tested ceiling, no load-balancer controller, a `restricted` namespace, no NetworkPolicy
enforcement *and* no dedicated node group, three nodes for four validators, a quota that
admits three validators of four, an `Immediate` StorageClass, a cluster-admin access
entry, no RBAC for our custom resources, and a node security group with no RPC ingress.

If the platform passes against it, **the platform's check is broken** — that is the
finding, not a reason to fix the fixture. A check that cannot fail is worse than no check,
because it is trusted.

> **This project creates clusters. The platform must never.** `../sbsa_besu` is forbidden
> from creating any cluster-scoped resource (D-23); that asymmetry is what protects the
> bank's real cluster, and the two briefs must not be blurred.

**It bills by the hour.** ~USD 0.10/hr for the control plane plus nodes in `af-south-1`.
Same-day teardown is mandatory.
