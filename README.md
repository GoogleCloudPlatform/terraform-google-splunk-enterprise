# Terraform templates for Splunk Enterprise on GCP

### Architecture Diagram

![Architecture Diagram of Splunk Enterprise on GCP](/img/splunk-on-gcp-diagram.png)

### Setup

1. Copy placeholder vars file `variables.yaml` into new `terraform.tfvars` to hold your own environment configurations.
2. Update placeholder values in `terraform.tfvars` to correspond to your GCP environment and desired Splunk settings.
3. Initialize Terraform working directory and download plugins by running `terraform init`.

#### Input Variables

Input | Description 
--- | ---
project | The project to deploy to, if not set the default provider project is used
region | Region for cloud resources
zone | Zone for cloud resources
splunk_idx_cluster_size | Size of Splunk indexer cluster (multi-zone)
splunk_sh_cluster_size | Size of Splunk search head cluster (multi-zone)
splunk_admin_password | Splunk admin password
splunk_cluster_secret | Splunk secret shared by indexer and search head clusters
splunk_indexer_discovery_secret | Splunk secret for indexer discovery

### Usage

```shell
$ terraform plan
$ terraform apply
```
