# Terraform templates for Splunk Enterprise on GCP

### Setup

1. Copy placeholder vars file `variables.yaml` into new `terraform.tfvars` to hold your own environment configurations.
2. Update placeholder values in `terraform.tfvars` to correspond to your GCP environment and desired Splunk settings.
3. Initialize Terraform working directory and download plugins by running `terraform init`.

### Usage

```shell
$ terraform plan
$ terraform apply
```
