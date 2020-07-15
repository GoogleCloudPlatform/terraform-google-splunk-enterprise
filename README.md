# Terraform templates for Splunk Enterprise on GCP

A set of Terraform templates to deploy distributed multi-zone Splunk Enterprise in a user-specified GCP region. Deployment includes a pre-configured indexer cluster where cluster master also acts as license master, as well as a pre-configured search head cluster with a deployer. Indexer cluster splunktcp and http event collector (HEC) input are pre-configured and ready to receive data. Search head cluster is fronted by a global load balancer for user web traffic. Indexer cluster is fronted by a global load balancer for HEC data traffic. For splunktcp data traffic, indexer discovery is pre-enabled so Splunk Forwarders can automatically discover list of peer nodes and natively load balance data across indexer cluster.

These deployment templates are provided for demo/POC purposes only.

### Architecture Diagram

![Architecture Diagram of Splunk Enterprise on GCP](./splunk-on-gcp-diagram.png)

### Configurable Parameters

Parameter | Description 
--- | ---
project | The project to deploy to, if not set the default provider project is used
region | Region for cloud resources
zone | Zone for cloud resources (if not specified first zone in region used)
splunk_idx_cluster_size | Size of Splunk indexer cluster (multi-zone)
splunk_sh_cluster_size | Size of Splunk search head cluster (multi-zone)
splunk_admin_password | Splunk admin password (No single quotes)
splunk_cluster_secret | Splunk secret shared by indexer and search head clusters (No single quotes)
splunk_indexer_discovery_secret | Splunk secret for indexer discovery (No single quotes)
splunk_network | Network to deploy Splunk onto (default splunk-network)
splunk_subnet | Subnetwork to deploy Splunk onto (default splunk-subnet)
splunk_subnet_cidr | Subnetwork CIDR for Splunk (default 192.168.0.0/16 - ignored if not creating network)
create_network | Boolean (default true) to create splunk network (set to false to reuse existing network)
idx_disk_type | Disk type to use for data volume on indexers.  Can be local-ssd, pd-ssd or pd-standard
idx_disk_size | Disk size for persistent disk data volumes (default 100 GB - ignored if using local-ssd in which case it's set to 375 GB)
idx_disk_count | Number of scratch disks to attach (default 1 - ignored if using pd-ssd or pd-standard in which cases there's only 1 PD)

### Getting Started

#### Requirements
* Terraform 0.12.20+

#### Setup working directory

1. Copy placeholder vars file `variables.yaml` into new `terraform.tfvars` to hold your own settings.
2. Update placeholder values in `terraform.tfvars` to correspond to your GCP environment and desired Splunk settings. See [list of input parameters](#configurable-parameters) above.
3. Initialize Terraform working directory and download plugins by running `terraform init`.

#### Deploy Splunk Enterprise

```shell
$ terraform plan
$ terraform apply
```

#### Access Splunk Enterprise

Once Terraform completes:

1. Confirm indexer cluster is configured correctly with all nodes up & running:
  * Navigate to `https://<splunk-cluster-master-public-ip>:8000/en-US/manager/system/clustering?tab=peers`

2. Visit Splunk web
  * Navigate to `http://<splunk-shc-splunkweb-address>/`
  * Login with 'admin' user and the password you specified (`splunk_admin_password`)

3. Send data to Splunk via Splunk Forwarders (Option A)
  * Point Splunk Forwarders to `https://<splunk-cluster-master-public-ip>:8089` to auto-discover indexers and forward data to indexer cluster directly. Configure forwarders with Splunk secret that you have specified (`splunk_indexer_discovery_secret`). Follow instructions [here](https://docs.splunk.com/Documentation/Splunk/7.2.6/Indexer/indexerdiscovery#3._Configure_the_forwarders) for more details.
 
4. Send data to Splunk via HEC (Option B)
  * Send data to HEC load balancer `http://<splunk-idx-hecinput-address:8080`. Use HEC token returned by Terraform. Refer to docs [here](https://docs.splunk.com/Documentation/Splunk/7.2.6/Data/UsetheHTTPEventCollector#Example_of_sending_data_to_HEC_with_an_HTTP_request) for example of an HTTP request to Splunk HEC.


### Cleanup

To delete resources created by Terraform, first type and confirm:
``` shell
$ terraform destroy
```

You also need to delete the indexers persistent disks since the indexer instance template is defined such that the disk is not auto-deleted when the instance is down or removed. This way, the auto-healing process by the instance group manager can re-attach the persistent disks to a new VM in the rare case where the indexer VM goes down or is unhealthy and needs to be recreated. You can run the following bash script which loops through all disks prefixed by 'splunk-idx' (per indexers instances names) and delete them one by one.  Note that deleting a disk is irreversible and any data on the disk will be lost.

``` shell
#!/bin/bash
for diskInfo in $(gcloud compute disks list --filter="name ~ '^splunk-idx'" --format="csv[no-heading](name,zone.scope(),type,size_gb)")
do
  echo "diskInfo: $diskInfo"
  IFS=',' read -ra diskInfoArray<<< "$diskInfo"
  NAME="${diskInfoArray[0]}"
  ZONE="${diskInfoArray[1]}"
  #echo "NAME: ${NAME}, ZONE: ${ZONE}"; echo ""
  gcloud compute disks delete $NAME --zone $ZONE
done
```

### TODOs

* Create & use base image with Splunk binaries + basic system & user configs
* Make startup script (Splunk configuration) more modular
* Delete instance metadata startup-script upon boot

### Authors

* **Roy Arsan** - [rarsan](https://github.com/rarsan)
* **Cuyler Dingwell** [c-dingwell](https://github.com/c-dingwell)

### Support

This is not an officially supported Google product. Terraform templates for Splunk Enterprise are developer and community-supported. Please don't hesitate to open an issue or pull request.

### Copyright & License

Copyright 2019 Google LLC

Terraform templates for Splunk Enterprise are licensed under the Apache license, v2.0. Details can be found in [LICENSE](./LICENSE) file.
