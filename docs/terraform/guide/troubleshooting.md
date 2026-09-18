# Terraform guide — Troubleshooting

[Index](../guide.md) · [Part 1](1-bootstrap.md) · [Part 2](2-shared-stack.md) · [Part 3](3-cluster-network.md) · [Part 4](4-cluster-nodes-and-load-balancers.md) · [Part 5](5-domain-certificate-and-secrets.md) · [Part 6](6-wireguard-and-private-rancher.md) · [Part 7](7-internal-uis.md)

---

| Symptom | Cause and fix |
|---|---|
| `Error acquiring the state lock` | Another plan or apply is running, or one was interrupted. If nothing is running: `terraform -chdir=infra/terraform/cluster force-unlock <LOCK_ID>` (or `shared`) |
| `BucketAlreadyExists` in step 4 | The bucket name is taken. Check `project` and the account ID in the name |
| `make: *** missing separator` | A Makefile recipe line starts with spaces instead of a tab |
| `no matching ECR Repository found` or a similar lookup error in step 9 | The shared stack is missing or in another region: run step 8 first |
| `AccessDenied` on the workstation | `aws sts get-caller-identity` must show the workstation role |
| `Author identity unknown` on `git commit` | Run the `git config --global` lines of step 7 |
| `InvalidParameterCombination: The specified instance type is not eligible for Free Tier` | The account is on the AWS Free plan: only free-tier-eligible types may be launched. Use `t3.small` or `m7i-flex.large`, or upgrade the account to a paid plan |
| `InsufficientInstanceCapacity` | Temporary shortage in one AZ: retry later, or fall back to `c7i-flex.large` (4 GB, the only other free-tier type big enough) and cut Prometheus retention |
| `no space left on device` during `terraform init` in CloudShell | `TF_DATA_DIR` is not set: the AWS provider needs about 830 MB and the CloudShell home folder holds 1 GB. Run `rm -rf .terraform`, then the exports of step 4, item 3, again |
| Budget stays at 0 USD | The `project` cost allocation tag is not active (step 6) |
| `dig NS` still shows the registrar's name servers | The change has not propagated, or it was entered in the wrong place: it is the **name server** setting of the domain, not a record inside the zone |
| The hosted-zone check in 17.2 prints two zone IDs | A second zone for the domain was created by hand. Keep the one whose name servers match `terraform -chdir=infra/terraform/shared output route53_name_servers`; in the Route 53 console, delete the records of the other zone, then the zone |
| `InvalidChangeBatch … is not permitted in zone` | The CNAME name was entered without `.recruitai.io.vn`. Run the two `read` lines of 17.2 again with the full name |
| Sectigo stays *pending validation* | `dig +short CNAME <full name> @1.1.1.1` must print Sectigo's value. If it is empty, the name is missing in Route 53, or doubled at the registrar (`….recruitai.io.vn.recruitai.io.vn`). Check the validation method is DNS (CNAME) |
| A `CAA` lookup names another certificate authority | Delete that `CAA` record in Route 53 and at the registrar, or add one that allows `sectigo.com` |
| In 17.3, the subject of `rancher.crt` names a Sectigo CA, not `rancher.recruitai.io.vn` | The bundle was pasted into `rancher.crt`. Paste the file issued to `rancher.recruitai.io.vn` into `rancher.crt` and the `.ca-bundle` into `ca-bundle.crt` (17.3, parts 2 and 3) |
| `unable to get local issuer certificate` in 17.3 | `ca-bundle.crt` is empty or incomplete. Paste the whole `.ca-bundle` file again (17.3, part 3) |
| `Could not read certificate` or `unable to load certificate` in 17.3 | The file is empty, or a paste lost its `BEGIN` or `END` line. Paste it again (17.3, part 2 or 3) |
| `MISMATCH` in 17.3 | The certificate was issued for a different request, usually because a new key was made after ordering. Reissue it on the Sectigo website with the current `rancher.csr` |
| `make infra` in step 18: `Tried to create resource record set … but it already exists` | A `rancher` or `vpn` record was copied into Route 53 in 17.1. Delete it in the console and run `make infra` again |
| `no matching Route 53 Hosted Zone found` in step 18 | Step 16 was not applied, or the two stacks use different domains |
| Existing records stopped resolving after step 17 | The DNS inventory was incomplete, or DNSSEC still has a stale DS record. Restore the missing records before continuing |
| WireGuard has no handshake | See 18.5, *If there is no handshake* |
| VPN connects but `rancher.recruitai.io.vn` does not resolve | The profile is missing `DNS = 10.10.0.2`, so the home router answered and dropped the private address. Add the line and reconnect; in PowerShell, `Resolve-DnsName rancher.recruitai.io.vn -Server 10.10.0.2` must return `10.10.x.x` addresses |
| VPN connects but Rancher is unreachable | Confirm the client routes `10.10.0.0/16`, `sudo iptables -S WG_FWD` on the gateway lists the 443 rule, and the internal NLB has a healthy 30443 target |
| Anything other than Rancher times out through the VPN | By design: the gateway forwards only DNS and TCP 443. Reach the Kubernetes API with `make tunnel` on the workstation |
| `cloud-init status` on the gateway shows `status: error` | The setup script stopped. See 18.5, *If there is no handshake* |
| `wg-quick` fails with `Chain already exists` | An earlier start stopped half-way. In a session on the gateway: `sudo iptables -D FORWARD -i wg0 -j WG_FWD; sudo iptables -F WG_FWD; sudo iptables -X WG_FWD; sudo systemctl restart wg-quick@wg0` |
| A node shows `ConnectionLost` in SSM | NAT gateway or route problem: check step 10, then reboot the instance |
