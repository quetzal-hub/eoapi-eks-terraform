# Observability stack: metrics come from the eoAPI chart itself (Prometheus +
# Grafana are enabled via `set` blocks on helm_release.eoapi); tracing is
# assembled here from cert-manager, the OpenTelemetry Operator, a Jaeger
# all-in-one backend, and an Instrumentation custom resource.

# ---------------------------------------------------------------------------
# cert-manager — prerequisite for the OTel Operator's admission webhooks
# ---------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version != "" ? var.cert_manager_chart_version : null
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# ---------------------------------------------------------------------------
# OpenTelemetry Operator
# ---------------------------------------------------------------------------
resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  version          = var.otel_operator_chart_version != "" ? var.otel_operator_chart_version : null
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  depends_on = [helm_release.cert_manager]
}

# ---------------------------------------------------------------------------
# Jaeger all-in-one — trace backend (Deployment + Service)
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "jaeger" {
  metadata {
    name      = "jaeger"
    namespace = var.eoapi_namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "jaeger"
      }
    }

    template {
      metadata {
        labels = {
          app = "jaeger"
        }
      }

      spec {
        container {
          name  = "jaeger"
          image = var.jaeger_image

          env {
            name  = "COLLECTOR_OTLP_ENABLED"
            value = "true"
          }

          port {
            container_port = 16686 # UI
          }
          port {
            container_port = 4317 # OTLP gRPC
          }
          port {
            container_port = 4318 # OTLP HTTP
          }
        }
      }
    }
  }

  depends_on = [helm_release.eoapi] # ensures the eoapi namespace exists
}

resource "kubernetes_service" "jaeger" {
  metadata {
    name      = "jaeger"
    namespace = var.eoapi_namespace
  }

  spec {
    selector = {
      app = "jaeger"
    }

    port {
      name        = "ui"
      port        = 16686
      target_port = 16686
    }
    port {
      name        = "otlp-grpc"
      port        = 4317
      target_port = 4317
    }
    port {
      name        = "otlp-http"
      port        = 4318
      target_port = 4318
    }
  }

  depends_on = [helm_release.eoapi]
}

# ---------------------------------------------------------------------------
# Instrumentation custom resource
# ---------------------------------------------------------------------------
# The endpoint deliberately targets port 4318 (OTLP HTTP), not 4317 (gRPC):
# the Operator's Python auto-instrumentation defaults to the http/protobuf
# export protocol, so pointing at the gRPC port makes every trace export
# fail silently.
resource "kubernetes_manifest" "eoapi_instrumentation" {
  manifest = {
    apiVersion = "opentelemetry.io/v1alpha1"
    kind       = "Instrumentation"
    metadata = {
      name      = "eoapi-instrumentation"
      namespace = var.eoapi_namespace
    }
    spec = {
      exporter = {
        endpoint = "http://jaeger.${var.eoapi_namespace}.svc.cluster.local:4318"
      }
      propagators = ["tracecontext", "baggage"]
      sampler = {
        type = "parentbased_always_on"
      }
    }
  }

  depends_on = [helm_release.otel_operator, kubernetes_service.jaeger]
}

# ---------------------------------------------------------------------------
# Enabling auto-instrumentation — intentionally a manual step
# ---------------------------------------------------------------------------
# The stac/raster/vector Deployments are owned by the `eoapi` Helm release,
# not by Terraform. Having Terraform patch objects it doesn't own causes
# constant plan/state drift against what Helm renders, so the inject
# annotation is applied post-deploy with kubectl instead:
#
#   kubectl patch deployment eoapi-stac   -n eoapi --patch-file manifests/otel-inject-patch.json
#   kubectl patch deployment eoapi-raster -n eoapi --patch-file manifests/otel-inject-patch.json
#   kubectl patch deployment eoapi-vector -n eoapi --patch-file manifests/otel-inject-patch.json
#
# This is a deliberate ownership boundary: Terraform owns infrastructure and
# the Instrumentation config; it does not reach into a Helm release's pod
# template.
