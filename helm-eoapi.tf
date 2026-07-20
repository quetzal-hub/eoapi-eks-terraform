resource "helm_release" "pgo" {
  name             = "pgo"
  repository       = "oci://registry.developers.crunchydata.com/crunchydata"
  chart            = "pgo"
  version          = var.pgo_chart_version
  namespace        = "postgres-operator"
  create_namespace = true

  set {
    name  = "disable_check_for_upgrades"
    value = "true"
  }
}

resource "helm_release" "eoapi" {
  name             = "eoapi"
  repository       = "https://devseed.com/eoapi-k8s/"
  chart            = "eoapi"
  version          = var.eoapi_chart_version
  namespace        = var.eoapi_namespace
  create_namespace = true
  timeout          = var.eoapi_helm_timeout

  # The chart's post-install hooks deadlock against Helm's --wait: the hook
  # jobs wait on pods that Helm won't mark ready until the hooks finish.
  # wait = false sidesteps that, at the cost of weaker drift detection.
  wait = false

  set {
    name  = "ingress.enabled"
    value = "false" # ingress is managed separately via the ALB controller (manifests/eoapi-alb-ingress.yaml)
  }

  # We disable the chart's own Ingress (above) but deliberately KEEP className at
  # its "nginx" default. The stac/raster/vector Deployments only receive the
  # `--root-path=/<service>`, `--proxy-headers`, and `--forwarded-allow-ips=*`
  # flags when className is "nginx" or "traefik" (see the chart's service
  # deployment templates). STAC is a HATEOAS API: without --root-path=/stac its
  # self/next/collection links come back missing the /stac prefix and 404 at our
  # ALB, which strips that prefix. Setting className to "alb" here would look
  # tidier but silently drop those flags and break every STAC link, so we set it
  # explicitly to nginx to guard against a future change to the chart default.
  set {
    name  = "ingress.className"
    value = "nginx"
  }
  set {
    name  = "monitoring.prometheus.enabled"
    value = "true"
  }
  set {
    name  = "observability.grafana.enabled"
    value = "true"
  }

  # Run the eoAPI services under a service account bound to the app IRSA role,
  # so the raster service can read COGs from S3 via temporary credentials
  # (no static keys). See module.eoapi_app_irsa in iam.tf.
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = var.eoapi_service_account_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eoapi_app_irsa.iam_role_arn
  }

  depends_on = [helm_release.pgo, helm_release.alb_controller]
}
