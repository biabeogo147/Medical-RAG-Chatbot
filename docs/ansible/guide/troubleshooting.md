# Ansible guide — Troubleshooting

[Index](../guide.md) · [Part 1](1-connection.md) · [Part 2](2-runtime.md) · [Part 3](3-control-plane.md) · [Part 4](4-network-and-kubectl.md) · [Part 5](5-prove-and-extend.md)

---

| Symptom | Cause and fix |
|---|---|
| `ansible-inventory --graph` shows no hosts | The nodes are not running (`make infra` first), or the tag or region in `inventory/aws_ec2.yml` does not match Terraform |
| `Failed to parse … with auto plugin` | The inventory file is not named `aws_ec2.yml`, or `make ansible-deps` has not been run |
| `couldn't resolve module/action 'amazon.aws.aws_ssm'` | Same cause: the collection is missing. Check with `ansible-galaxy collection list amazon.aws` |
| `requires ansible-core 2.17` | A newer `amazon.aws` was installed by hand. `ansible-galaxy collection install -r infra/ansible/requirements.yml --force` puts the pinned 10.3.2 back |
| `aws_account_id is undefined` | The playbook was started directly instead of through `make cluster` |
| `TargetNotConnected` on `make ping` | The SSM agent has not registered yet. `aws ssm describe-instance-information` must list the node as `Online`; a node that never appears has no NAT route |
| `Failed to upload file to S3` | The `ssm-transfer` bucket is missing or in another region. It belongs to the cluster stack, so run `make infra` |
| Tasks hang and then fail with a timeout | The Session Manager session dropped. Run it again; the playbook is idempotent |
| `dpkg` lock errors | unattended-upgrades is holding it on a freshly booted node; the roles wait up to 5 minutes for it. Run it again |
| `kubeadm init` or a join fails part-way, and the next run reports that port 6443 is in use | Reset that one node and run again. From `infra/ansible`: `ansible medical-rag-node-2 -b -e project=medical-rag -e aws_region=ap-southeast-1 -e aws_account_id=$(aws sts get-caller-identity --query Account --output text) -m command -a "kubeadm reset -f"`, then `make cluster` |
| After resetting a node that had already joined, the next join fails on `check-etcd` | Its old etcd member is still registered. List the members with the `etcdctl` command in [step 7](3-control-plane.md#step-7--the-kubeadm_join-role), then `member remove <id>` before `make cluster` |
| `NTPSynchronized` never becomes `yes` in the `common` role | The node cannot reach the time service. Check the NAT route and the security group, then reboot the instance |
| Nodes stay `NotReady` after [step 8](4-network-and-kubectl.md#step-8--the-cni_calico-and-untaint_control_plane-roles) | Calico is still pulling images: `make kubectl CMD="get pods -n calico-system"`. If pods stay `Pending`, the control-plane taint is still there — step 8 |
| A join fails with `error execution phase check-etcd` | The previous join has not finished; `serial: 1` prevents this, so check that the play really has it |
| `x509: certificate is valid for …, not 127.0.0.1` | The cluster was built before `certSANs` contained `127.0.0.1`. Fix the template, then rebuild the API server certificate on each node with `kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml` |
| `The connection to the server 127.0.0.1:6443 was refused` | The `make tunnel` window was closed, or node 1 is stopped |
