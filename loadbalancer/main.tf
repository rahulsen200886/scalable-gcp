# Kubernetes Deployment and Service
resource "kubernetes_deployment" "web_app_us" {
  metadata {
    name      = "web-app-us"
    namespace = "default"
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "web-app-us"
      }
    }

    template {
      metadata {
        labels = {
          app = "web-app-us"
        }
      }

      spec {
        container {
          name  = "web-app"
          image = "nginx:latest"

          ports {
            container_port = 443
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "web_app_service_us" {
  metadata {
    name      = "web-app-service-us"
    namespace = "default"
    annotations = {
      "cloud.google.com/neg" = jsonencode({
        exposed_ports = {
          "443" = {}
        }
      })
    }
  }

  spec {
    selector = {
      app = kubernetes_deployment.web_app_us.metadata[0].labels.app
    }

    port {
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "web_app_eu" {
  metadata {
    name      = "web-app-eu"
    namespace = "default"
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "web-app-eu"
      }
    }

    template {
      metadata {
        labels = {
          app = "web-app-eu"
        }
      }

      spec {
        container {
          name  = "web-app"
          image = "nginx:latest"

          ports {
            container_port = 443
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "web_app_service_eu" {
  metadata {
    name      = "web-app-service-eu"
    namespace = "default"
    annotations = {
      "cloud.google.com/neg" = jsonencode({
        exposed_ports = {
          "443" = {}
        }
      })
    }
  }

  spec {
    selector = {
      app = kubernetes_deployment.web_app_eu.metadata[0].labels.app
    }

    port {
      port        = 443
      target_port = 443
    }

    type = "ClusterIP"
  }
}

# GCP HTTPS Load Balancer
resource "google_compute_global_address" "lb_ip" {
  name = "web-app-lb-ip"
}

resource "google_compute_health_check" "https_health_check" {
  name               = "https-health-check"
  check_interval_sec = 5
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 2

  https_health_check {
    port = 443
  }
}

resource "google_compute_backend_service" "web_backend_service_us" {
  name                  = "web-backend-service-us"
  load_balancing_scheme = "EXTERNAL"
  protocol              = "HTTPS"
  port_name             = "https"

  backend {
    group = kubernetes_service.web_app_service_us.metadata[0].annotations["cloud.google.com/neg"].exposed_ports["443"].name
  }

  health_checks = [google_compute_health_check.https_health_check.id]
  security_policy = google_compute_security_policy.web_security_policy.id
}

resource "google_compute_backend_service" "web_backend_service_eu" {
  name                  = "web-backend-service-eu"
  load_balancing_scheme = "EXTERNAL"
  protocol              = "HTTPS"
  port_name             = "https"

  backend {
    group = kubernetes_service.web_app_service_eu.metadata[0].annotations["cloud.google.com/neg"].exposed_ports["443"].name
  }

  health_checks = [google_compute_health_check.https_health_check.id]
  security_policy = google_compute_security_policy.web_security_policy.id
}

resource "google_compute_url_map" "web_url_map" {
  name = "web-url-map"

  default_service = google_compute_backend_service.web_backend_service_us.id

  host_rule {
    hosts        = ["us.your-domain.com"]
    path_matcher = "us-matcher"
  }

  host_rule {
    hosts        = ["eu.your-domain.com"]
    path_matcher = "eu-matcher"
  }

  path_matcher {
    name            = "us-matcher"
    default_service = google_compute_backend_service.web_backend_service_us.id
  }

  path_matcher {
    name            = "eu-matcher"
    default_service = google_compute_backend_service.web_backend_service_eu.id
  }
}

resource "google_compute_target_https_proxy" "web_https_proxy" {
  name            = "web-https-proxy"
  url_map         = google_compute_url_map.web_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.web_ssl_cert.id]
}

resource "google_compute_global_forwarding_rule" "web_forwarding_rule" {
  name       = "web-https-forwarding-rule"
  target     = google_compute_target_https_proxy.web_https_proxy.id
  port_range = "443"
  ip_address = google_compute_global_address.lb_ip.address
}

# Managed SSL Certificate
resource "google_compute_managed_ssl_certificate" "web_ssl_cert" {
  name = "web-ssl-cert"
  managed {
    domains = ["your-domain.com", "us.your-domain.com", "eu.your-domain.com"] # Replace with your domains
  }
}

# Cloud Armor Security Policy
resource "google_compute_security_policy" "web_security_policy" {
  name = "web-security-policy"

  rule {
    priority    = 1000
    action      = "allow"
    description = "Allow traffic from specific IP ranges"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["0.0.0.0/0"]  # Adjust to your IP whitelist
      }
    }
  }

  rule {
    priority    = 2000
    action      = "deny(403)"
    description = "Deny all other traffic"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "load_balancer_ip" {
  value = google_compute_global_address.lb_ip.address
}
