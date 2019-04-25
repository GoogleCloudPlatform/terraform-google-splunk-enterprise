
variable project {
  description = "The project to deploy to, if not set the default provider project is used."
  default     = ""
}

variable region {
  description = "Region for cloud resources"
  default     = "us-central1"
}

variable zone {
  description = "Zone for cloud resources"
  default     = "us-central1-c"
}

variable splunk_admin_password {
  description = "Splunk admin password"
  default     = ""
}
