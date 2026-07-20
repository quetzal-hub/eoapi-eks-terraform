# eoAPI on AWS EKS via Terraform

[![Terraform CI](../../actions/workflows/terraform.yml/badge.svg)](../../actions/workflows/terraform.yml)
[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.5-844FBA?logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Infrastructure-as-code deployment of the [eoAPI](https://eoapi.dev) geospatial
stack (STAC metadata, raster tiling, vector features) onto Amazon EKS, using
Terraform. Provisions the cluster with the community AWS modules and deploys the
application and observability stack via Terraform's Helm and Kubernetes
providers.

This is one of two implementations of the same system built deliberately with
different tools; see the companion [CDK version](https://github.com/quetzal-hub/eoapi-eks-cdk)
for a direct comparison. This Terraform build was done *second*, so it applies every
lesson the CDK build taught.

## What this deploys

- **Cluster (via Terraform):** a VPC, an EKS cluster (Kubernetes 1.34), a managed
  node group, and the AWS Load Balancer Controller, using the
  `terraform-aws-modules/vpc` and `terraform-aws-modules/eks` community modules.
- **IRSA roles (via Terraform):** IAM Roles for Service Accounts for the EBS CSI
  driver, the ALB controller, and the eoAPI application itself (scoped S3 read
  access so the raster service can stream COGs), all built from a data source
  rather than hand-typed ARNs.
- **Application (via Helm provider):** PostgreSQL via the CrunchyData Postgres
  operator, plus the eoAPI services (STAC, raster, vector) backed by pgSTAC.
- **Ingress:** public access via an **Application Load Balancer** using the ALB
  controller's **native URL-rewrite** feature (controller v3.4.2).
- **Observability:** Prometheus + Grafana for metrics, and OpenTelemetry
  auto-instrumentation feeding Jaeger for distributed tracing, with no
  application code changes required.

## Architecture

```
Browser → ALB (native URL rewrite) → VPC → EKS cluster → { STAC, Raster, Vector } → Postgres
                                              │
                                              └── Observability: Prometheus/Grafana, OpenTelemetry/Jaeger
```

**Design principle: Terraform owns infrastructure and configuration; Helm owns
the application; a few live-cluster patches stay manual by design.** Terraform
provisions everything and manages the Helm releases, but the pod-annotation step
that enables OpenTelemetry auto-instrumentation is left as a manual `kubectl
patch`. Those Deployments are owned by the eoAPI Helm release, and having
Terraform patch objects it doesn't own causes constant state drift.

## Repository layout

| Path | Contents |
|------|----------|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | Provider config, including the `kubernetes`/`helm` providers wired to the cluster |
| `variables.tf` | All tunable inputs, with working defaults |
| `outputs.tf` | Cluster endpoint, IRSA role ARNs, kubeconfig command |
| `network.tf` | VPC module |
| `eks.tf` | EKS cluster module |
| `iam.tf` | OIDC data source + IRSA role modules |
| `storage.tf` | EBS CSI addon + default gp3 StorageClass |
| `helm-ingress.tf` | AWS Load Balancer Controller release |
| `helm-eoapi.tf` | Postgres operator + eoAPI release |
| `observability.tf` | cert-manager, OpenTelemetry operator, Jaeger, Instrumentation |
| `manifests/eoapi-alb-ingress.yaml` | ALB Ingress with native URL-rewrite annotations |
| `manifests/otel-inject-patch.json` | Pod-annotation patch enabling OTel auto-instrumentation |
| `terraform.tfvars.example` | Example variable overrides |

## Prerequisites

- AWS account with credentials configured
- Terraform >= 1.5
- `kubectl` and `helm`

## Configuration

Every input has a working default (see [`variables.tf`](variables.tf)); to
customize, copy `terraform.tfvars.example` to `terraform.tfvars` and edit. The
most useful knobs:

| Variable | Default | Purpose |
|----------|---------|---------|
| `aws_region` | `us-west-2` | Deployment region (keep `availability_zones` in sync) |
| `cluster_name` | `eoapi-tf-cluster` | EKS cluster name |
| `kubernetes_version` | `1.34` | EKS control-plane version |
| `node_instance_types` | `["t3.medium"]` | Node group instance types |
| `node_group_min_size` / `max` / `desired` | `2` / `3` / `2` | Node group sizing |
| `single_nat_gateway` | `true` | One shared NAT gateway (cheap) vs. one per AZ (resilient) |
| `tags` | project/managed-by | Applied to all AWS resources via `default_tags` |

## Deploy

Because a single Terraform config both *creates* the cluster and *configures
resources inside it*, apply in two steps to avoid the provider chicken-and-egg
problem:

```bash
terraform init

# Step 1: create the cluster's control plane first, so the kubernetes/helm
# providers below have something real to connect to. Target BOTH the VPC and
# EKS modules explicitly (see the note below on why).
terraform apply -target="module.vpc" -target="module.eks"

# Step 2: immediately follow with a full apply; this is what actually
# provisions IRSA roles, storage, the application, ingress, and observability.
# Do not stop after step 1.
terraform apply

# Step 2a: if step 2 failed on the Instrumentation resource, it's a CRD
# registration race: the OpenTelemetry Operator hasn't finished registering
# its CRD with the API server by the time Terraform tries to use it. This has
# happened on every from-scratch deploy so far; expect to need it.
terraform apply -target="helm_release.otel_operator"
terraform apply   

# 3. Point kubectl at the cluster (also printed as the `configure_kubectl` output)
aws eks update-kubeconfig --region <region> --name eoapi-tf-cluster

# 4. Create the public ALB ingress with native URL rewriting
kubectl apply -f manifests/eoapi-alb-ingress.yaml

# 5. Enable OpenTelemetry auto-instrumentation (manual, by design)
#    Use a patch file on Windows/PowerShell to avoid quoting issues:
kubectl patch deployment eoapi-stac   -n eoapi --patch-file manifests/otel-inject-patch.json
kubectl patch deployment eoapi-raster -n eoapi --patch-file manifests/otel-inject-patch.json
kubectl patch deployment eoapi-vector -n eoapi --patch-file manifests/otel-inject-patch.json
```

**Why `-target="module.eks"` alone isn't enough:** `-target` doesn't pull in
everything a module transitively depends on, only the specific resources
needed to produce the values that target actually *consumes*. `module.eks`
reads the VPC's subnet IDs, so subnets get created, but nothing in `module.eks`
reads the NAT gateway's ID, so Terraform has no reason to include it in scope.
Result: subnets exist, but their route tables point at a NAT gateway that was
never created, so node group instances launch into a private subnet with no
path out, and fail to join the cluster (`NodeCreationFailure`, visible as a
`DescribeInstances` timeout loop in the instance console log). Targeting
`module.vpc` explicitly alongside `module.eks` avoids this.

**If you land on a `CREATE_FAILED` node group** (for example, from running step
1 without the VPC target): confirm the NAT gateway now exists and is
`available` (`aws ec2 describe-nat-gateways`), then force the node group to
retry (`terraform plan` doesn't always detect a failed-but-still-tracked node
group on its own):
```bash
terraform apply -replace="module.eks.module.eks_managed_node_group[\"default\"].aws_eks_node_group.this[0]"
```

## Verify

```bash
kubectl get ingress -n eoapi
```

Take the `ADDRESS` column and hit the real endpoints (allow a couple of minutes
for DNS to propagate on a freshly created load balancer, which has happened on
every build so far):

```
http://<address>/stac/
http://<address>/raster/
http://<address>/vector/
```

A working `/stac/` response confirms the full chain (cluster, ingress, native
ALB rewrite, application, and database) is actually serving real traffic, not
just that `terraform apply` exited cleanly.

## Accessing Grafana and Jaeger

Neither is exposed through the Ingress. They're reached via `kubectl
port-forward` only:

```bash
kubectl port-forward -n eoapi svc/eoapi-grafana 3000:80
kubectl port-forward -n eoapi svc/jaeger 16686:16686
```

This is a deliberate choice, not a shortcut left unfinished. Port-forwarding is
genuinely the right call for a single-user, cost-conscious learning cluster:
no extra always-on load balancer billing, and no dashboard sitting on the
public internet behind nothing but a login page. In a real production
environment, internal tools like these would typically sit behind a VPN or
bastion (never public), or be replaced entirely by a managed offering like
Amazon Managed Grafana (not exposed via a plain public Ingress the way the
application API is).

## What this build does differently from the CDK version

Each of these is a deliberate decision informed by having built the system
once already; three are pre-emptions of bugs the CDK build hit, and one is a
choice made to work directly with the AWS-native ingress path:

- **IRSA built from a data source, not by hand.** The IAM trust policies are
  derived from `data.aws_iam_openid_connect_provider.eks.arn`, a real resolved
  value, so the malformed-ARN bug that broke the CDK build's EBS CSI driver is
  structurally impossible here.
- **`wait = false` set from the start.** The Helm hook / `--wait` deadlock is a
  chart-level issue, not a CDK one; it would bite Terraform's `helm_release`
  too. Setting `wait = false` up front avoided it entirely.
- **The OTLP endpoint points at port 4318 from the start.** The silent
  gRPC/HTTP port mismatch from the CDK build was pre-empted in the
  `Instrumentation` resource.
- **AWS-native ingress, by deliberate choice.** In the CDK build the eoAPI Helm
  chart managed the Ingress, and the chart's schema only permits an
  `ingress.className` of `nginx` or `traefik`, so that build used nginx. Here I
  set `ingress.enabled = false` on the eoAPI release and defined a standalone
  ALB Ingress (`manifests/eoapi-alb-ingress.yaml`) whose own `ingressClassName`
  is `alb`, using the controller's native `transforms` URL-rewrite annotation
  (ALB controller v3.4.2). This was a deliberate move to work directly with the
  AWS-native ingress path, not a verdict that ALB beats nginx; nginx remains a
  perfectly valid, more portable default. (Note that the *Helm release* keeps
  its `ingress.className` value at `nginx` even so; that value creates no
  Ingress here, it only triggers the chart to inject `--root-path` into the app
  pods. The two settings live at different layers, explained next.)

## A real finding: the rewrite regex edge case

The AWS-documented rewrite pattern `^\/stac\/(.+)$` correctly rewrites
`/stac/collections` → `/collections`, but **does not match the bare prefix**
(`/stac` or `/stac/`), because `(.+)` requires at least one character after the
slash. The fix is a more defensive pattern that makes the trailing segment
optional:

```
^\/stac(?:\/(.*))?$
```

This handles the bare prefix, the trailing slash, and subpaths alike, covering
a gap the official example itself doesn't.

## Making self-referential links work behind the prefix

STAC is a HATEOAS API: its responses are full of hyperlinks (`self`, `next`,
`collection`), so a service exposed under `/stac` must generate links that
*include* that prefix, or clients that follow them hit paths the ALB doesn't
route. FastAPI handles this with `--root-path`, and the eoAPI chart wires
`--root-path=/<service>` (plus `--proxy-headers`) onto the STAC/raster/vector
Deployments, but only when `ingress.className` is `nginx` or `traefik`.

Two settings that both read like "class name" are doing genuinely different
jobs here, and it's worth being explicit so the config doesn't look
contradictory:

| Setting | Where it lives | What it does in this build |
|---------|----------------|----------------------------|
| `ingressClassName: alb` | the standalone Ingress in `manifests/eoapi-alb-ingress.yaml` | the *real* class: it's what makes the ALB controller provision the load balancer and route traffic |
| `ingress.className: nginx` | a value on the eoAPI Helm release | creates **no** Ingress (the chart's Ingress is off via `ingress.enabled=false`); it only triggers the chart to inject `--root-path` into the app pods |

Because the chart couples that `--root-path` injection to `className` being
`nginx`/`traefik` (not to `ingress.enabled`), it would be tempting to set the
release's `ingress.className: alb` to "match" the ALB. That silently drops the
`--root-path` flags and breaks every STAC link. So the release keeps
`className` explicitly at `nginx`: the services still receive `--root-path`,
and the ALB's own rewrite strips the prefix on the way in. The result mirrors
exactly what the chart does for nginx, by design rather than by accident.

## Some hard-won operational notes

- **Provider chicken-and-egg / CRD timing** both need the two-step apply
  pattern. Terraform sequences resource *creation* well, but doesn't always
  guarantee a dependent *system* (a reachable cluster endpoint, a queryable
  CRD) is ready the instant the triggering resource reports success.
- **`wait = false` weakens Terraform's drift detection.** Because Terraform
  doesn't block on the release settling, its state can believe a release matches
  config when it doesn't. (In this build, a mis-placed `set` block silently
  landed on the wrong release and Terraform reported "no changes", worth knowing
  as a real tradeoff of the deadlock fix.)
- **On Windows/PowerShell, pass JSON to `kubectl` via `--patch-file`,** not
  inline `-p '...'`; PowerShell mangles inline JSON when handing it to native
  executables.
- **State is local by default.** Fine for a single-operator demo; for anything
  shared, add an S3 backend with state locking (`use_lockfile` or DynamoDB)
  before collaborating.

## Cost note

This stack is not free-tier: expect roughly ~$0.10/hr for the EKS control
plane, plus two `t3.medium` nodes, a NAT gateway, an ALB, and EBS volumes.
Destroy it when you're done experimenting.

## Teardown

```bash
# Remove the ingress first so the ALB controller deletes its load balancer
kubectl delete -f manifests/eoapi-alb-ingress.yaml

terraform destroy
```

Terraform unwinds the dependency graph in order (Helm releases before the
cluster, cluster before the VPC). Confirm afterward in the console that no EKS
cluster and no load balancers remain, especially any load balancer the ALB
controller provisioned in response to the Ingress, which can occasionally
outlive the destroy.

## License

[MIT](LICENSE)
