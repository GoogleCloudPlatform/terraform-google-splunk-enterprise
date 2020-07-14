# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

####
## VPC
####
resource "google_compute_network" "vpc_network" {
  count                   = var.create_network ? 1 : 0
  name                    = var.splunk_network
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "splunk_subnet" {
  count         = var.create_network ? 1 : 0
  name          = var.splunk_subnet
  ip_cidr_range = var.splunk_subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc_network[0].self_link
}

resource "google_compute_address" "splunk_cluster_master_ip" {
  name         = "splunk-cm-ip"
  address_type = "INTERNAL"
  subnetwork = var.create_network ? google_compute_subnetwork.splunk_subnet[0].self_link : var.splunk_subnet 
}

resource "google_compute_address" "splunk_deployer_ip" {
  name         = "splunk-deployer-ip"
  address_type = "INTERNAL"
  subnetwork   = var.create_network ? google_compute_subnetwork.splunk_subnet[0].self_link : var.splunk_subnet
}

resource "google_compute_global_forwarding_rule" "search_head_cluster_rule" {
  name       = "splunk-shc-splunkweb-rule"
  target     = google_compute_target_http_proxy.search_head_cluster_proxy.self_link
  ip_address = google_compute_global_address.search_head_cluster_address.address
  port_range = "80"
}

resource "google_compute_global_address" "search_head_cluster_address" {
  name = "splunk-shc-splunkweb-address"
}

resource "google_compute_target_http_proxy" "search_head_cluster_proxy" {
  name    = "splunk-shc-splunkweb-proxy"
  url_map = google_compute_url_map.search_head_cluster_url_map.self_link
}

resource "google_compute_url_map" "search_head_cluster_url_map" {
  name            = "splunk-shc-splunkweb-url-map"
  default_service = google_compute_backend_service.default.self_link
}

resource "google_compute_backend_service" "default" {
  name      = "shc-splunkweb"
  port_name = "splunkweb"
  protocol  = "HTTP"

  backend {
    group          = google_compute_region_instance_group_manager.search_head_cluster.instance_group
    balancing_mode = "UTILIZATION"
  }

  health_checks = [google_compute_health_check.default.self_link]

  session_affinity        = "GENERATED_COOKIE"
  affinity_cookie_ttl_sec = "86400"
  enable_cdn              = true

  connection_draining_timeout_sec = "300"
}

resource "google_compute_global_forwarding_rule" "indexer_hec_input_rule" {
  name       = "splunk-idx-hecinput-rule"
  target     = google_compute_target_http_proxy.indexer_hec_input_proxy.self_link
  ip_address = google_compute_global_address.indexer_hec_input_address.address
  port_range = "8080"
}

resource "google_compute_global_address" "indexer_hec_input_address" {
  name = "splunk-idx-hecinput-address"
}

resource "google_compute_target_http_proxy" "indexer_hec_input_proxy" {
  name    = "splunk-idx-hecinput-proxy"
  url_map = google_compute_url_map.indexer_hec_input_url_map.self_link
}

resource "google_compute_url_map" "indexer_hec_input_url_map" {
  name            = "splunk-idx-hecinput-url-map"
  default_service = google_compute_backend_service.splunk_hec.self_link
}

resource "google_compute_backend_service" "splunk_hec" {
  name      = "idx-splunk-hec"
  port_name = "splunkhec"
  protocol  = "HTTPS"
  backend {
    group          = google_compute_region_instance_group_manager.indexer_cluster.instance_group
    balancing_mode = "UTILIZATION"
  }
  health_checks = [google_compute_health_check.splunk_hec.self_link]
  connection_draining_timeout_sec = "300"
}

####
## Firewall Rules
####
resource "google_compute_firewall" "allow_internal" {
  name    = "splunk-network-allow-internal"
  network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_tags = ["splunk"]
  target_tags = ["splunk"]
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "splunk-network-allow-health-checks"
  network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network

  allow {
    protocol = "tcp"
    ports    = ["8089", "8088"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["splunk"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "splunk-network-allow-ssh"
  network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["splunk"]
}

resource "google_compute_firewall" "allow_splunk_web" {
  name    = "splunk-network-allow-web"
  network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  target_tags = ["splunk"]
}

####
## Health Checks
####
resource "google_compute_health_check" "default" {
  name                = "shc-mgmt-port-health-check"
  check_interval_sec  = 15
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = "8089"
  }

  depends_on = [google_compute_firewall.allow_health_checks]
}

resource "google_compute_health_check" "splunk_hec" {
  name                = "idx-hec-port-health-check"
  check_interval_sec  = 15
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  https_health_check {
    request_path = "/services/collector/health"
    port         = "8088"
  }

  depends_on = [google_compute_firewall.allow_health_checks]
}

resource "google_compute_health_check" "splunk_idx" {
  name                = "idx-mgmt-port-health-check"
  check_interval_sec  = 30
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 4 # 2 minutes

  https_health_check {
    request_path = "/"
    port         = "8089"
  }

  depends_on = [google_compute_firewall.allow_health_checks]
}

