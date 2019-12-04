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
}

provider "google-beta" {
  project = var.project
  region  = var.region
}

locals {
  splunk_package_name = "splunk-8.0.0-1357bef0a7f6-Linux-x86_64.tgz"
  splunk_package_url = "http://download.splunk.com/products/splunk/releases/8.0.0/linux/${local.splunk_package_name}"
  splunk_cluster_master_name = "splunk-cluster-master"
  zone    = var.zone == "" ? data.google_compute_zones.available.names[0] : var.zone
}


data "template_file" "splunk_startup_script" {
  template = file(format("${path.module}/startup_script.sh.tpl"))

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

data "google_compute_zones" "available" {
    region = var.region
}

output "indexer_cluster_hec_token" {
  value = "${module.shell_output_token.stdout}"
}

output "indexer_cluster_page" {
  value = "https://${google_compute_instance.splunk_cluster_master.network_interface.0.access_config.0.nat_ip}:8000"
}