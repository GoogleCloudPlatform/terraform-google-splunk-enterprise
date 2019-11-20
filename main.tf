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
  splunk_package_name = "splunk-8.0.0-1357bef0a7f6-Linux-x86_64.tgz"
  splunk_package_url = "http://download.splunk.com/products/splunk/releases/8.0.0/linux/${local.splunk_package_name}"
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
  count = var.create_network ? 1 : 0
  name                    = var.splunk_network
  auto_create_subnetworks = "true"
}

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
    disk_type    = "pd-ssd"
    disk_size_gb = "50"
    boot         = "true"
  }

  network_interface {
    network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network
    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "SHC-Member"
    enable-guest-attributes = "TRUE"
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
    google_compute_instance.splunk_deployer,
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
      type  = "pd-ssd"
      size  = "50"
    }
  }

  network_interface {
    network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network
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
      type  = "pd-ssd"
      size  = "50"
    }
  }

  network_interface {
    network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network
    network_ip = google_compute_address.splunk_deployer_ip.address

    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "SHC-Deployer"
    enable-guest-attributes = "TRUE"
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
    disk_type    = "pd-ssd"
    disk_size_gb = "50"
    boot         = "true"
  }

  network_interface {
    network = var.create_network ? google_compute_network.vpc_network[0].name : var.splunk_network
    access_config {
      # Ephemeral IP
    }
  }

  metadata = {
    startup-script = data.template_file.splunk_startup_script.rendered
    splunk-role    = "IDX-Peer"
    enable-guest-attributes = "TRUE"
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

# Continuously check for HEC token for output
module "shell_output_token" {
  source = "matti/resource/shell"
  version = "0.12.0"
  command =  <<CMD
sleep 10
until \
token=`gcloud compute instances get-guest-attributes ${google_compute_instance.splunk_cluster_master.id} --zone ${google_compute_instance.splunk_cluster_master.zone} --query-path=splunk/token --format="value(VALUE)" --quiet 2> /dev/null`
do sleep 10
done
echo $token
CMD
}

# Wait until successful install then remove startup-script from instance metadata
# Note, doesn't remove from instance template
module "shell_output_install_progress" {
  source = "matti/resource/shell"
  version = "0.12.0"
  command = <<CMD
sleep 30
until gcloud compute instances list --format="value(name,zone)" --filter="metadata['items']['key']=splunk-role" |  \
awk '
BEGIN {r=0;h="";t="";c=0}
{
cmd = "gcloud compute instances get-guest-attributes "$1" --zone "$2" --query-path=splunk/install --format=\"value(VALUE)\" 2> /dev/null"
rv=""
rs=""
cmd | getline rv
cmd = "gcloud compute instances get-guest-attributes "$1" --zone "$2" --query-path=splunk/install-status --format=\"value(VALUE)\" 2> /dev/null"
cmd | getline rs
if (rv == "") { rv = "booting" }
if (rv != "complete") { r = 1; h = h" "$1 }
t=sprintf("%s\n %-25s %-14s %s",t,$1,rv,rs)
c=c+1
}
END {
print "Install progress:"t
if (c == 0) { r=1; }
if (h != "" && c!=0) {
  print "Still installing on hosts: "h
}
exit r
}'
do sleep 15
done
echo "All hosts completed install, now removing metadata from hosts"
gcloud compute instances list --format="value(name,zone)" --filter="metadata['items']['key']=splunk-role" | \
awk '{system("gcloud compute instances remove-metadata "$1" --zone "$2" --keys startup-script --quiet")}'
CMD
}

output "indexer_cluster_hec_token" {
  value = "${module.shell_output_token.stdout}"
}

