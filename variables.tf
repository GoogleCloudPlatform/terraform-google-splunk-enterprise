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
variable "project" {
  description = "Project for Splunk deployment"
}

variable "region" {
  description = "Region to deploy to"
}

variable "zone" {
  description = "Zone to deploy master and deployer into"
  default = ""
}

variable "splunk_idx_cluster_size" {
  description = "Number of nodes in Splunk indexer cluster"
  default     = 3
}

variable "splunk_sh_cluster_size" {
  description = "Number of nodes in Splunk search head cluster"
  default     = 3
}

variable "splunk_admin_password" {
  description = "Splunk admin password"

   validation {
     condition = !can(regex("[$()']", var.splunk_admin_password))
     error_message = "Admin password cannot contain any of the following illegal characters: ' ( ) $."
   }
}

variable "splunk_cluster_secret" {
  description = "Splunk cluster secret"

  validation {
    condition = !can(regex("[$()']", var.splunk_cluster_secret))
    error_message = "Cluster secret cannot contain any of the following illegal characters: ' ( ) $."
  }
}

variable "splunk_indexer_discovery_secret" {
  description = "Splunk indexer discovery secret"

  validation {
    condition = !can(regex("[$()']", var.splunk_indexer_discovery_secret))
    error_message = "Indexer discovery secret cannot contain any of the following illegal characters: ' ( ) $."
  }
}

variable "splunk_network" {
  description = "Network to attach Splunk nodes to"
  default = "splunk-network"
}


variable "splunk_subnet" {
  description = "Subnet to attach Splunk nodes to"
  default = "splunk-subnet"
}

variable "splunk_subnet_cidr" {
  description = "Subnet CIDR to attach Splunk nodes to"
  default = "192.168.0.0/16"
}

variable "create_network" {
  description = "Create Splunk Network (true or false)"
  type = bool
  default = true
}


variable "idx_disk_type" {
  description = "Disk type to use for data volume on indexers.  Can be local-ssd, pd-ssd or pd-standard"
  type = string
  default = "pd-ssd"
}

variable "idx_disk_size" {
  description = "Default disk size for persistent disk data volumes (if not using local-ssd)"
  type = number
  default = 100
}

# Only used for Local SSD's
variable "idx_disk_count" {
  description = "Number of disks to attach if using local-ssd (each volume 375 GB)"
  type = number
  default = 1
}
