
####
## Local Scripts
####

# Continuously check for HEC token for output
module "shell_output_token" {
  source = "matti/resource/shell"
  version = "0.12.0"
  command =  <<CMD
sleep 10
until \
token=`gcloud compute instances get-guest-attributes ${local.splunk_cluster_master_name} --zone ${local.zone} --query-path=splunk/token --format="value(VALUE)" --quiet 2> /dev/null`
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
until gcloud compute instances list --format="value(name,zone)" --filter="metadata['items']['key']=splunk-role" | sort |  \
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