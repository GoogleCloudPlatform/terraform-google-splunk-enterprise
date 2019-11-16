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
  description = "The project to deploy to, if not set the default provider project is used."
}

variable "region" {
  description = "Region for cloud resources"
}

variable "zone" {
  description = "Zone for cloud resources"
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
}

variable "splunk_cluster_secret" {
  description = "Splunk cluster secret"
}

variable "splunk_indexer_discovery_secret" {
  description = "Splunk indexer discovery secret"
}

variable "splunk_network" {
  description = "Network to attach Splunk nodes to"
  default = "splunk-network"
}

variable "create_network" {
  description = "Create Splunk Network (true or false)"
  type = bool
  default = true
}

