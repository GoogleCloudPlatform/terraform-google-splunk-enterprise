/* Copyright 2019 Google LLC. This software is provided as-is, without warranty or representation for any use or purpose. Your use of it is subject to your agreements with Google. */

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

provider "google-beta" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

locals {
  splunk_package_url = "http://download.splunk.com/products/splunk/releases/7.2.6/linux/splunk-7.2.6-c0bf0f679ce9-Linux-x86_64.tgz"
  splunk_package_name = "splunk-7.2.6-c0bf0f679ce9-Linux-x86_64.tgz"
}

data "template_file" "splunk_startup_script" {
  template = file(format("%s/startup_script.sh.tpl", path.module))

  vars = {
    SPLUNK_PACKAGE_URL              = local.splunk_package_url
    SPLUNK_PACKAGE_NAME             = local.splunk_package_name
    SPLUNK_ADMIN_PASSWORD           = var.splunk_admin_password
    SPLUNK_CLUSTER_SECRET           = var.splunk_cluster_secret
    SPLUNK_INDEXER_DISCOVERY_SECRET = var.splunk_indexer_discovery_secret
    SPLUNK_CM_PRIVATE_IP            = google_compute_address.splunk_cluster_master_ip.address
    SPLUNK_DEPLOYER_PRIVATE_IP      = google_compute_address.splunk_deployer_ip.address
  }

  depends_on = [
    google_compute_address.splunk_cluster_master_ip,
    google_compute_address.splunk_deployer_ip,
  ]
}

resource "google_compute_network" "vpc_network" {
  name                    = "splunk-network"
  auto_create_subnetworks = "true"
}

resource "google_compute_firewall" "allow_internal" {
  name    = "splunk-network-allow-internal"
  network = google_compute_network.vpc_network.name

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
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["8089"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["splunk"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "splunk-network-allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["splunk"]
}

resource "google_compute_firewall" "allow_splunk_web" {
  name    = "splunk-network-allow-web"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  target_tags = ["splunk"]
}

resource "google_compute_address" "splunk_cluster_master_ip" {
  name         = "splunk-cm-ip"
  address_type = "INTERNAL"
}

resource "google_compute_address" "splunk_deployer_ip" {
  name         = "splunk-deployer-ip"
  address_type = "INTERNAL"
}

resource "google_compute_instance_template" "splunk_shc_template" {
  name_prefix  = "splunk-shc-template-"
  machine_type = "n1-standard-4"

  tags = ["splunk"]

  # boot disk
  disk {
    source_image = "ubuntu-os-cloud/ubuntu-1604-lts"
    disk_type    = "pd-standard"
    disk_size_gb = "50"
    boot         = "true"
  }

  network_interface {
    network = google_compute_network.vpc_network.self_link
    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "SHC-Member"
  }
}

resource "google_compute_region_instance_group_manager" "search_head_cluster" {
  provider           = google-beta
  name               = "splunk-shc-mig"
  region             = var.region
  base_instance_name = "splunk-sh"

  target_size = var.splunk_sh_cluster_size

  version {
    name              = "splunk-shc-mig-version-0"
    instance_template = google_compute_instance_template.splunk_shc_template.self_link
  }

  named_port {
    name = "splunkweb"
    port = "8000"
  }

  depends_on = [
    google_compute_instance.splunk_cluster_master,
    google_compute_instance_template.splunk_shc_template
  ]
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

resource "google_compute_instance" "splunk_cluster_master" {
  name         = "splunk-cluster-master"
  machine_type = "n1-standard-4"

  tags = ["splunk"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1604-lts"
      type  = "pd-standard"
      size  = "50"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.self_link
    network_ip = google_compute_address.splunk_cluster_master_ip.address

    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "IDX-Master"
    enable-guest-attributes = "TRUE"
  }

  depends_on = [
    google_compute_firewall.allow_internal,
    google_compute_firewall.allow_ssh,
    google_compute_firewall.allow_splunk_web,
  ]
}

resource "google_compute_instance" "splunk_deployer" {
  name         = "splunk-deployer"
  machine_type = "n1-standard-4"

  tags = ["splunk"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1604-lts"
      type  = "pd-standard"
      size  = "50"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.self_link
    network_ip = google_compute_address.splunk_deployer_ip.address

    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "SHC-Deployer"
  }

  depends_on = [
    google_compute_firewall.allow_internal,
    google_compute_firewall.allow_ssh,
    google_compute_firewall.allow_splunk_web,
  ]
}

resource "google_compute_instance_template" "splunk_idx_template" {
  name_prefix  = "splunk-idx-template-"
  machine_type = "n1-standard-4"

  tags = ["splunk"]

  # boot disk
  disk {
    source_image = "ubuntu-os-cloud/ubuntu-1604-lts"
    disk_type    = "pd-standard"
    disk_size_gb = "50"
    boot         = "true"
  }

  network_interface {
    network = google_compute_network.vpc_network.self_link
    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "IDX-Peer"
  }
}

resource "google_compute_region_instance_group_manager" "indexer_cluster" {
  provider           = google-beta
  name               = "splunk-idx-mig"
  region             = var.region
  base_instance_name = "splunk-idx"

  target_size = var.splunk_idx_cluster_size

  version {
    name              = "splunk-idx-mig-version-0"
    instance_template = google_compute_instance_template.splunk_idx_template.self_link
  }

  named_port {
    name = "splunkhec"
    port = "8088"
  }

  named_port {
    name = "splunktcp"
    port = "9997"
  }

  depends_on = [google_compute_instance.splunk_cluster_master]
}

module "shell_output" {
  source = "matti/resource/shell"
  version = "0.12.0"
  command = "sleep 10; until gcloud compute instances get-guest-attributes ${google_compute_instance.splunk_cluster_master.id} --query-path=splunk/token --format=\"value(VALUE)\" --quiet; do sleep 10; done"
}

output "indexer_cluster_hec_token" {
  value = module.shell_output.stdout
}

