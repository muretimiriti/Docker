**DevOps Security Integration Guide**

Understanding start-security.sh

*A complete guide for security beginners*

Covers: Vault • External Secrets • Kyverno • Cosign • Helm • Kubernetes

**1. What Is This Script?**

The file start-security.sh is a Bash automation script that sets up the
security layer of a Kubernetes-based DevOps pipeline. Think of it as a
\"security installer\" --- you run it once and it provisions all the
moving parts that keep your cluster safe.

In plain terms, it does three things:

-   Installs the External Secrets Operator (ESO) --- which pulls secrets
    (passwords, API keys, certificates) out of a central vault and makes
    them available inside Kubernetes without hard-coding them into your
    code.

-   Installs Kyverno --- a Kubernetes-native policy engine that acts as
    a gatekeeper, enforcing rules about what can and cannot run in your
    cluster.

-   Applies security manifests --- YAML configuration files that wire
    everything together: telling ESO where to find secrets, and telling
    Kyverno what policy to enforce.

  --------- -------------------------------------------------------------
  **WHY**   Before this kind of setup, secrets like database passwords
            were often stored directly in code or in environment variable
            files committed to Git. That is a major security risk. This
            script implements modern secret management and policy
            enforcement in an automated, repeatable way.

  --------- -------------------------------------------------------------

**2. The Key Components Explained**

**2.1 HashiCorp Vault**

Vault is a dedicated secrets management tool. Instead of scattering
passwords and API keys across your codebase, you store them all in Vault
--- a single encrypted, audited, access-controlled store. Vault supports
multiple authentication methods so different systems can securely prove
their identity and retrieve only the secrets they are entitled to.

  -------------------------- --------------------------------------------
  **Vault Concept**          **What It Means For You**

  **KV (Key-Value) Engine**  The storage backend inside Vault where your
                             secrets live. Like a secure folder tree.

  **Auth Mode**              How Vault verifies the identity of whoever
                             is asking for a secret (AppRole, JWT token,
                             or static token).

  **Mount Path**             The URL path at which the KV engine is
                             accessible --- defaults to \'kv\' in this
                             script.

  **AppRole**                A machine-to-machine auth method: your
                             service has a Role ID (like a username) and
                             a Secret ID (like a password).

  **JWT Auth**               Uses a Kubernetes service account token ---
                             the pod proves who it is via a signed JWT.
                             No passwords needed.
  -------------------------- --------------------------------------------

**2.2 External Secrets Operator (ESO)**

ESO is a Kubernetes controller that bridges the gap between Vault (or
any secrets backend) and Kubernetes. It watches for ExternalSecret
custom resources in your cluster and automatically syncs the referenced
secrets from Vault into Kubernetes Secrets, keeping them up to date.

  ------------- -------------------------------------------------------------
  **ANALOGY**   Think of ESO as a trusted courier. Vault is a secure
                safe-deposit box. ESO picks up the secrets and delivers them
                to your application\'s doorstep inside Kubernetes --- without
                your app ever needing to know the safe combination.

  ------------- -------------------------------------------------------------

The script installs ESO using Helm (the Kubernetes package manager) and
then creates a ClusterSecretStore --- a cluster-wide configuration that
tells ESO how to connect to Vault.

**2.3 Kyverno**

Kyverno is a policy engine built specifically for Kubernetes. It
intercepts every request to create or update a resource (a pod, a
deployment, a secret) and checks it against your defined policies before
allowing it through. Policies can validate, mutate (automatically
modify), or generate resources.

In this script, Kyverno is used to enforce image verification ---
ensuring that every container image deployed to your cluster has been
cryptographically signed with Cosign. Unsigned or tampered images are
rejected.

  -------------------------- --------------------------------------------
  **Kyverno Mode**           **Behaviour**

  **Enforce (default)**      Blocks any resource that violates policy.
                             The deployment simply does not happen.

  **Audit**                  Allows the resource but logs a violation.
                             Useful when you are first rolling out
                             policies and want to observe without
                             breaking things.
  -------------------------- --------------------------------------------

**2.4 Cosign (Image Signing)**

Cosign is a tool for signing and verifying container images. When your
CI/CD pipeline builds a Docker image, it signs it with a private key.
Kyverno then uses the corresponding public key to verify that every
image running in your cluster was built by your pipeline and has not
been tampered with since.

  ------------- -------------------------------------------------------------
  **ANALOGY**   Think of Cosign like a wax seal on an envelope. If the seal
                is intact and matches the expected stamp, you know the
                contents haven\'t been tampered with. If the seal is broken
                or missing, you reject the letter.

  ------------- -------------------------------------------------------------

**2.5 Helm**

Helm is the package manager for Kubernetes --- similar to apt or brew
but for cluster software. The script uses Helm to install both ESO and
Kyverno with a single command each, handling all the CRDs (Custom
Resource Definitions), service accounts, and RBAC rules automatically.

**3. How the Script Operates --- Step by Step**

When you run ./scripts/k8s/start-security.sh, here is exactly what
happens in sequence:

**Step 1: Parse Arguments & Validate Prerequisites**

The script first reads all the flags you pass on the command line and
sets variables accordingly. It then checks that kubectl is installed and
that you can actually reach a Kubernetes cluster. If either check fails,
the script exits immediately with a clear error.

**Step 2: Install External Secrets Operator (unless skipped)**

> helm repo add external-secrets https://charts.external-secrets.io
>
> helm upgrade \--install external-secrets
> external-secrets/external-secrets \\
>
> \--namespace external-secrets \--create-namespace \--set
> installCRDs=true

This installs ESO into its own namespace called external-secrets. The
\--set installCRDs=true flag installs the Custom Resource Definitions
that let you write ExternalSecret and ClusterSecretStore resources in
YAML.

**Step 3: Install Kyverno (unless skipped)**

> helm upgrade \--install kyverno kyverno/kyverno \\
>
> \--namespace kyverno \--create-namespace \\
>
> \--set global.image.registry=ghcr.io

Kyverno is installed into its own namespace called kyverno. The image
registry flag tells Helm where to pull the Kyverno container images from
--- by default GitHub Container Registry (ghcr.io), but this can be
changed if you use a private mirror.

**Step 4: Upload Cosign Public Key (if provided)**

If you supply a \--cosign-public-key-file, the script reads that PEM
file and creates a Kubernetes Secret called cosign-public-key in the
kyverno namespace. Kyverno\'s verify policy will reference this secret
to validate image signatures.

**Step 5: Apply the ClusterSecretStore**

This is the most complex step. The script reads one of three template
YAML files --- one per Vault auth mode --- substitutes your actual
values (Vault address, role IDs, secret names) using awk string
replacement, and then applies the resulting YAML to your cluster with
kubectl apply.

  -------------------------- --------------------------------------------
  **Auth Mode**              **What manifest is used**

  **token**                  cluster-secret-store-vault-token.yaml ---
                             simplest; uses a static Vault token stored
                             as a K8s Secret.

  **approle (default)**      cluster-secret-store-vault-approle.yaml ---
                             uses a Role ID + Secret ID pair. More secure
                             than token.

  **jwt**                    cluster-secret-store-vault-jwt.yaml --- uses
                             Kubernetes service account JWT tokens. No
                             long-lived credentials.
  -------------------------- --------------------------------------------

**Step 6: Apply ExternalSecret for Tekton**

The script applies tekton-secrets.externalsecret.yaml, which defines
which Vault secrets should be synced into the tekton-pipelines (or
similar) namespace. This is how your CI pipeline gets the credentials it
needs at runtime.

**Step 7: Apply Kyverno Image Verification Policy**

Finally, the script applies the Cosign verification policy. If
\--cosign-public-key-file was provided, it embeds the PEM key directly
into the policy YAML. If \--audit-policy was passed, it switches
validationFailureAction from Enforce to Audit (so policy violations are
logged but not blocked).

**4. Prerequisites --- Everything You Need Before Running**

**4.1 Tools to Install on Your Machine**

  -------------------------- --------------------------------------------
  **Tool**                   **Installation & Purpose**

  **kubectl**                The Kubernetes CLI. Install via: brew
                             install kubectl (Mac) or follow
                             kubernetes.io/docs/tasks/tools

  **helm**                   The Kubernetes package manager. Install via:
                             brew install helm or
                             helm.sh/docs/intro/install

  **cosign**                 For signing images and generating key pairs.
                             Install via: brew install cosign or
                             docs.sigstore.dev

  **vault CLI (optional)**   Useful for debugging Vault connectivity.
                             Install via: brew install vault
  -------------------------- --------------------------------------------

**4.2 Kubernetes Cluster**

You need a running Kubernetes cluster with cluster-admin privileges. The
script will check connectivity automatically. Options for getting a
cluster:

-   Local development: kind (Kubernetes in Docker) or minikube

-   Cloud: AWS EKS, Google GKE, Azure AKS, or DigitalOcean Kubernetes

-   Minimum version: Kubernetes 1.21+ (for all CRDs to work correctly)

**4.3 HashiCorp Vault**

You need a running Vault instance accessible from inside your cluster.
The default URL assumed by the script is
https://vault.vault.svc.cluster.local:8200, which means Vault is running
inside the cluster in the vault namespace. If Vault is external, pass
its URL via \--vault-addr.

For AppRole mode (default), you must:

1.  Enable the AppRole auth method in Vault: vault auth enable approle

2.  Create a policy in Vault that grants read access to your KV secrets

3.  Create an AppRole tied to that policy

4.  Retrieve the Role ID: vault read auth/approle/role/my-role/role-id

5.  Generate a Secret ID: vault write -f
    auth/approle/role/my-role/secret-id

6.  Store the Secret ID as a Kubernetes Secret in the external-secrets
    namespace

**4.4 Cosign Key Pair**

For the image verification policy to work in Enforce mode, you need a
Cosign key pair. Generate one with:

> cosign generate-key-pair

This creates cosign.key (private --- keep this secret, store in Vault or
CI secrets) and cosign.pub (public --- this is what you pass to the
script via \--cosign-public-key-file).

Your CI/CD pipeline must sign images after building them:

> cosign sign \--key cosign.key your-registry/your-image:tag

**4.5 Required Manifest Files**

The script references several YAML files that must exist in your
repository at these paths:

-   manifests/security/external-secrets/cluster-secret-store-vault-token.yaml

-   manifests/security/external-secrets/cluster-secret-store-vault-approle.yaml

-   manifests/security/external-secrets/cluster-secret-store-vault-jwt.yaml

-   manifests/security/external-secrets/tekton-secrets.externalsecret.yaml

-   manifests/security/kyverno/verify-cosign-policy.yaml

**5. How to Run the Script**

**5.1 Minimal Run (Token Auth, Audit Mode --- safest for first-timers)**

> ./scripts/k8s/start-security.sh \\
>
> \--vault-auth-mode token \\
>
> \--vault-addr https://my-vault.example.com:8200 \\
>
> \--vault-token-secret vault-token \\
>
> \--audit-policy

  --------- -------------------------------------------------------------
  **TIP**   Use \--audit-policy when first setting things up. This lets
            Kyverno log violations without blocking workloads, so you can
            observe the impact before enforcing.

  --------- -------------------------------------------------------------

**5.2 Full Run (AppRole Auth, Enforce Mode with Image Signing)**

> ./scripts/k8s/start-security.sh \\
>
> \--vault-addr https://vault.vault.svc.cluster.local:8200 \\
>
> \--vault-auth-mode approle \\
>
> \--vault-approle-role-id abc123-role-id-here \\
>
> \--cosign-public-key-file ./cosign.pub

**5.3 Skip Individual Steps**

> \# Only install ESO, skip Kyverno and manifests
>
> ./scripts/k8s/start-security.sh \--skip-install-kyverno \--skip-apply
>
> \# Only apply manifests (tools already installed)
>
> ./scripts/k8s/start-security.sh \--skip-install-eso
> \--skip-install-kyverno

**6. All Flags at a Glance**

  ------------------------------- --------------------------------------------
  **Flag**                        **Description**

  **\--skip-install-eso**         Do not install External Secrets Operator
                                  (assumes it is already installed).

  **\--skip-install-kyverno**     Do not install Kyverno.

  **\--skip-apply**               Do not apply any manifests. Only install
                                  tools.

  **\--audit-policy**             Set Kyverno policy to Audit mode instead of
                                  Enforce.

  **\--vault-addr \<url\>**       Full URL of your Vault server. Default:
                                  https://vault.vault.svc.cluster.local:8200

  **\--vault-path \<path\>**      The KV mount path in Vault. Default: kv

  **\--vault-version \<v1\|v2\>** Vault KV engine version. Default: v2

  **\--vault-auth-mode \<mode\>** How ESO authenticates with Vault: token,
                                  approle, or jwt. Default: approle

  **\--vault-approle-role-id**    The AppRole Role ID string (required for
                                  approle mode).

  **\--vault-approle-secret       Name of the K8s Secret holding the AppRole
  \<name\>**                      Secret ID. Default: vault-approle

  **\--vault-approle-secret-key   Key within that Secret that holds the Secret
  \<k\>**                         ID value. Default: secret-id

  **\--vault-token-secret         Name of the K8s Secret holding a static
  \<name\>**                      Vault token. Default: vault-token

  **\--vault-jwt-path \<path\>**  Vault JWT auth mount path. Default: jwt

  **\--vault-jwt-role \<role\>**  Vault role name for JWT auth. Default:
                                  external-secrets

  **\--cosign-public-key-file     Path to your cosign.pub file. Required for
  \<f\>**                         Enforce mode.

  **\--kyverno-image-registry     Docker registry to pull Kyverno images from.
  \<r\>**                         Default: ghcr.io
  ------------------------------- --------------------------------------------

**7. Recommended First-Time Setup Order**

  ---------- -------------------------------------------------------------
  **NOTE**   Follow these steps in order. Each step depends on the
             previous one being complete.

  ---------- -------------------------------------------------------------

7.  Install kubectl, helm, and cosign on your local machine.

8.  Ensure kubectl can reach your cluster: kubectl cluster-info

9.  Deploy HashiCorp Vault (or get credentials for an existing one).

10. Enable and configure your chosen Vault auth method (AppRole or JWT).

11. Store your AppRole Secret ID (or Vault token) as a Kubernetes Secret
    in the external-secrets namespace.

12. Generate a Cosign key pair: cosign generate-key-pair

13. Store cosign.key safely (CI secret / Vault). Keep cosign.pub
    accessible.

14. Ensure all five required manifest YAML files exist in your
    repository.

15. Run the script in audit mode first to validate connectivity.

16. Integrate cosign sign into your CI/CD pipeline so new images are
    signed.

17. Re-run the script without \--audit-policy to switch to Enforce mode.

**8. Common Errors and What They Mean**

  ----------------------------- --------------------------------------------
  **Error Message**             **Cause & Fix**

  **kubectl not found**         kubectl is not installed or not on your
                                PATH. Install it and retry.

  **Cannot reach Kubernetes     Your kubeconfig is wrong, the cluster is
  cluster**                     down, or VPN is needed. Run kubectl
                                cluster-info to diagnose.

  **helm not found**            Helm is not installed. Required for ESO and
                                Kyverno installation.

  **approle mode requires       You chose AppRole auth but did not provide
  \--vault-approle-role-id**    the Role ID. Add \--vault-approle-role-id
                                \<id\>.

  **Enforce mode requires       You are running in Enforce mode but have not
  \--cosign-public-key-file**   provided a Cosign public key. Kyverno cannot
                                verify images without it.

  **Cosign public key file not  The path you gave to
  found**                       \--cosign-public-key-file does not exist.
                                Check the path.

  **Unsupported vault auth      You passed an invalid value to
  mode**                        \--vault-auth-mode. Only token, approle, and
                                jwt are accepted.
  ----------------------------- --------------------------------------------

**9. Core Security Concepts in Plain English**

  -------------------------- --------------------------------------------
  **Concept**                **Plain English Explanation**

  **Secrets Management**     Never store passwords in code. Use a
                             dedicated secrets vault and have your app
                             fetch them at runtime.

  **Least Privilege**        Each service should only be able to access
                             the secrets it actually needs --- nothing
                             more.

  **Image Integrity**        Cryptographically verify that the container
                             image running in production is exactly what
                             your CI/CD built --- not a tampered version.

  **Policy as Code**         Define security rules in version-controlled
                             YAML files (Kyverno policies), not as
                             informal checklists.

  **Audit vs Enforce**       Start in Audit mode to observe; switch to
                             Enforce only when you are confident policies
                             won\'t break your workloads.

  **Zero Long-Lived          JWT auth eliminates static secrets entirely
  Credentials**              --- Kubernetes service account tokens prove
                             identity dynamically.
  -------------------------- --------------------------------------------

*End of Document*
