#!/usr/bin/env bash
# One unattended, timed rebuild of the cluster stack: empty stack -> every Argo CD Application Synced and
# Healthy. Produces the CV's [T] and [17] (docs/evidence/guide-measurements.md, M3) without anyone typing
# `yes` or copying screens. Run it from the repository root on the ops workstation, after `make down`:
#
#   bash infra/scripts/timed-rebuild.sh
#
# Everything goes to /tmp/timed-rebuild-<UTC>.log. The SUMMARY at the end ends in VERDICT PASS or FAIL; only a
# PASS is a measurement. Unlike M3's manual procedure there is no human `yes` prompt inside T: the plan is
# checked by the script instead.
#
# Safety: the cluster stack must be empty, the Terraform plan is applied only if it creates and neither changes
# nor destroys anything, and the shared and bootstrap stacks are never touched.
set -uo pipefail

EXPECTED_APPS=${EXPECTED_APPS:-17}     # the 16 files in deploy/argocd/apps plus root
PING_TIMEOUT=${PING_TIMEOUT:-900}      # seconds for all three SSM agents to register
REBOOT_AFTER=${REBOOT_AFTER:-300}      # seconds before a node SSM has never heard of is rebooted, once
API_TIMEOUT=${API_TIMEOUT:-300}        # seconds for the tunnel to reach the API
APPS_TIMEOUT=${APPS_TIMEOUT:-3600}     # seconds for every Application to be Synced and Healthy
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-ap-southeast-1}

cd "$(dirname "$0")/../.." || exit 1
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
P=/tmp/timed-rebuild-$STAMP
LOG=$P.log
exec > >(tee -a "$LOG") 2>&1

now()  { date -u +%FT%TZ; }
secs() { date -u +%s; }
dur()  { local s=$1; printf '%dm%02ds' $((s / 60)) $((s % 60)); }
PHASE="preconditions"
TUNNEL_PID=""
mark() { PHASE="$*"; echo; echo "=== $(now) $*"; }
fail() {
  echo; echo "!!! $(now) FAILED during: $PHASE"; echo "!!! reason: $*"; echo "!!! log: $LOG"
  case "$PHASE" in
    preconditions*|"t0: terraform plan"*) echo "!!! nothing was created." ;;
    *bootstrap*|*Applications*) echo "!!! the cluster exists. Clean up with: make down" ;;
    *) echo "!!! nodes may exist but Argo CD does not. Clean up with: make infra-destroy (not make down)" ;;
  esac
  [ -n "$TUNNEL_PID" ] && echo "!!! a tunnel is running: kill -- -$TUNNEL_PID"
  exit 1
}
CLUSTER="terraform -chdir=infra/terraform/cluster"
kc() { kubectl --request-timeout=10s "$@"; }
tunnel_alive() { [ -z "$TUNNEL_PID" ] || kill -0 "$TUNNEL_PID" 2>/dev/null || fail "the tunnel exited (log $P-tunnel.log)"; }

# --- preconditions, not timed ---------------------------------------------------------------------------
mark "preconditions"
make init >/dev/null || fail "make init"
state=$($CLUSTER state list 2>&1) || fail "terraform state list: $state"
n_state=$(printf '%s\n' "$state" | grep -c . || true)
[ "$n_state" -eq 0 ] || fail "the cluster stack still holds $n_state resources; run 'make down' first"
# A tunnel from the previous cluster: the aws CLI and its session-manager-plugin child both hold port 6443.
pkill -f 'start-session.*localPortNumber=6443' 2>/dev/null
pkill -f 'session-manager-plugin.*6443' 2>/dev/null
sleep 2
ss -ltn 'sport = :6443' | grep -q LISTEN && fail "something still listens on 127.0.0.1:6443; stop it first"
echo "cluster stack empty; port 6443 free"

# --- the clock -----------------------------------------------------------------------------------------
T0=$(secs); T0_ISO=$(now)
mark "t0: terraform plan"
$CLUSTER plan -input=false -no-color -out="$P.tfplan" > "$P-plan.txt" 2>&1
rc=$?; tail -3 "$P-plan.txt"
[ "$rc" -eq 0 ] || fail "terraform plan exited $rc"
summary=$(grep -E '^Plan: ' "$P-plan.txt")
echo "$summary" | grep -qE ' 0 to change, 0 to destroy' || fail "plan is not create-only: $summary"
mark "terraform apply ($summary)"
$CLUSTER apply -input=false -no-color "$P.tfplan" > "$P-apply.txt" 2>&1
rc=$?; tail -2 "$P-apply.txt"; rm -f "$P.tfplan"
[ "$rc" -eq 0 ] || fail "terraform apply exited $rc"
T_INFRA=$(secs)

# A node's SSM agent has failed two ways here: registering late (2026-09-22, node 2 answered on the second
# ping), and never registering, because the agent started before the role's credentials were in IMDS
# (docs/evidence/ansible.md, node 2 row; fixed by one reboot). Keep pinging; after REBOOT_AFTER seconds, reboot
# once any node SSM has no record of at all. An AWS error is never read as "no record".
REBOOTED=""
wait_for_ssm() {   # $1 = when this wait started, in seconds
  local start=$1 out down node id ping
  while true; do
    out=$(make ping 2>&1)
    [ "$(printf '%s\n' "$out" | grep -c ' | SUCCESS')" -eq 3 ] && return 0
    [ $(( $(secs) - start )) -lt "$PING_TIMEOUT" ] || fail "SSM did not answer on all three nodes within $(dur "$PING_TIMEOUT")"
    down=$(printf '%s\n' "$out" | grep -oE '^medical-rag-node-[0-9]+ \| (FAILED|UNREACHABLE)' | cut -d' ' -f1)
    echo "$(now) not answering: $(echo $down)"
    if [ $(( $(secs) - start )) -ge "$REBOOT_AFTER" ]; then
      for node in $down; do
        case " $REBOOTED " in *" $node "*) continue ;; esac
        id=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$node" "Name=instance-state-name,Values=running" \
               --query 'Reservations[0].Instances[0].InstanceId' --output text) || { echo "  $node: describe-instances failed"; continue; }
        [[ $id == i-* ]] || { echo "  $node: no running instance ($id)"; continue; }
        ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
                 --query 'InstanceInformationList[0].PingStatus' --output text) || { echo "  $node: SSM query failed; not rebooting"; continue; }
        if [ "$ping" = "None" ]; then
          echo "  $node ($id): SSM has no record of it after $(dur $(( $(secs) - start ))); rebooting it once"
          aws ec2 reboot-instances --instance-ids "$id" && REBOOTED="$REBOOTED $node"
        else
          echo "  $node ($id): SSM says $ping; waiting, not rebooting"
        fi
      done
    fi
    sleep 20
  done
}
mark "waiting for SSM on all three nodes"
wait_for_ssm "$T_INFRA"
T_PING=$(secs)

# site.yml is safe to re-run once it is past kubeadm, and not while a kubeadm init or join may be half done:
# kubeadm_init takes admin.conf, written early, as "done". So a lost SSM session is retried once, and only
# when the failed run never reached a kubeadm task. Anything else stops here.
CLUSTER_RUNS=0
while true; do
  CLUSTER_RUNS=$((CLUSTER_RUNS + 1))
  mark "make cluster (run $CLUSTER_RUNS)"
  make cluster > "$P-ansible.txt" 2>&1
  rc=$?; grep -A4 'PLAY RECAP' "$P-ansible.txt"
  [ "$rc" -eq 0 ] && break
  cp "$P-ansible.txt" "$P-ansible-run$CLUSTER_RUNS.txt"
  if [ "$CLUSTER_RUNS" -lt 2 ] && grep -q 'TargetNotConnected' "$P-ansible.txt" \
     && ! grep -qE 'TASK \[kubeadm_(init|join)' "$P-ansible.txt"; then
    echo "$(now) an SSM session dropped before any kubeadm task; waiting for the nodes, then running it again"
    wait_for_ssm "$(secs)"
    continue
  fi
  fail "make cluster exited $rc (output: $P-ansible-run$CLUSTER_RUNS.txt)"
done
recap=$(grep -E '^medical-rag-node-[0-9]+ +:' "$P-ansible.txt")
[ "$(printf '%s\n' "$recap" | grep -c 'failed=0 ')" -eq 3 ] || fail "PLAY RECAP does not show failed=0 for all three nodes"
printf '%s\n' "$recap" | grep -qE 'unreachable=[1-9]' && fail "an Ansible host was unreachable"
T_CLUSTER=$(secs)

mark "tunnel (background, log $P-tunnel.log)"
setsid nohup make tunnel > "$P-tunnel.log" 2>&1 < /dev/null &
TUNNEL_PID=$!
until kc get --raw /readyz >/dev/null 2>&1; do
  tunnel_alive
  [ $(( $(secs) - T_CLUSTER )) -lt "$API_TIMEOUT" ] || fail "the API did not answer through the tunnel"
  sleep 5
done
echo "API answers through the tunnel (process group $TUNNEL_PID)"

mark "make bootstrap"
make bootstrap > "$P-bootstrap.txt" 2>&1
rc=$?; tail -2 "$P-bootstrap.txt"
[ "$rc" -eq 0 ] || fail "make bootstrap exited $rc"
T_BOOT=$(secs)

# Synced and Healthy on every one, and no sync operation still running: hooks such as the index-build Job are
# left out of health, so an Application can read Healthy while its PostSync hook still runs.
mark "waiting for $EXPECTED_APPS Applications, every one Synced, Healthy and not mid-sync"
while true; do
  tunnel_alive
  out=$(kc -n argocd get applications \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}{end}' 2>/dev/null)
  n=$(printf '%s\n' "$out" | grep -c . || true)
  bad=$(printf '%s\n' "$out" | awk 'NF && ($2 != "Synced" || $3 != "Healthy" || $4 == "Running")' | grep -c . || true)
  echo "$(now) apps=$n pending=$bad"
  [ "$n" -ge "$EXPECTED_APPS" ] && [ "$bad" -eq 0 ] && break
  [ $(( $(secs) - T_BOOT )) -lt "$APPS_TIMEOUT" ] || fail "Applications not all Synced and Healthy after $(dur "$APPS_TIMEOUT")"
  sleep 15
done
TE=$(secs); TE_ISO=$(now)
# --- the clock stops here ------------------------------------------------------------------------------

mark "confirm a minute later, and the checks that are not timed"
sleep 60
tunnel_alive
verdict=PASS; why=""
apps_after=$(kc -n argocd get applications --no-headers) || { verdict=FAIL; why="$why; apps unreadable"; }
echo "$apps_after"
n_after=$(printf '%s\n' "$apps_after" | grep -c . || true)
bad_after=$(printf '%s\n' "$apps_after" | awk 'NF && ($2 != "Synced" || $3 != "Healthy")' | grep -c . || true)
[ "$n_after" -ge "$EXPECTED_APPS" ] && [ "$bad_after" -eq 0 ] || { verdict=FAIL; why="$why; $bad_after of $n_after not Synced+Healthy a minute later"; }
if crs_out=$(kc -n ingress-nginx get certificaterequests --no-headers 2>&1); then
  crs=$(printf '%s\n' "$crs_out" | grep -vc 'No resources found' || true)
  [ -z "$crs_out" ] && crs=0
else
  crs="unreadable"; verdict=FAIL; why="$why; certificaterequests unreadable"
fi
[ "$crs" = "0" ] || { verdict=FAIL; why="$why; CertificateRequests: $crs"; }
oidc=$(make oidc-check 2>&1)
[ "$(printf '%s\n' "$oidc" | grep -c '^same ')" -eq 2 ] || { verdict=FAIL; why="$why; oidc-check did not print two 'same' lines"; }
nodes=$(kc get nodes --no-headers 2>/dev/null | awk '{print $1, $2, $5}')
[ "$(printf '%s\n' "$nodes" | grep -c ' Ready ')" -eq 3 ] || { verdict=FAIL; why="$why; not three Ready nodes"; }

cat <<EOF

================================ SUMMARY ================================
log                 $LOG
t0                  $T0_ISO
end                 $TE_ISO
T (wall clock)      $(dur $((TE - T0)))    <- CV [T]   (no human prompt inside it; polling adds up to ~35 s)
  terraform         $(dur $((T_INFRA - T0)))   ($summary)
  SSM registration  $(dur $((T_PING - T_INFRA)))   (rebooted:${REBOOTED:- none})
  make cluster      $(dur $((T_CLUSTER - T_PING)))   ($CLUSTER_RUNS run(s))
  tunnel+bootstrap  $(dur $((T_BOOT - T_CLUSTER)))
  Argo CD waves     $(dur $((TE - T_BOOT)))
Applications        $n at the end; a minute later $n_after, of which $bad_after not Synced+Healthy    <- CV [17]
CertificateRequests $crs   (0 = the wildcard was restored; otherwise a Let's Encrypt issuance was spent)
oidc-check          $(printf '%s\n' "$oidc" | grep -E '^(same|DIFFERENT|MISSING)' | tr -s ' ' | tr '\n' ';')
nodes               $(printf '%s\n' "$nodes" | tr '\n' ';')
tunnel              running as process group $TUNNEL_PID; stop it with: kill -- -$TUNNEL_PID
VERDICT             $verdict${why:+ ($why)}
==========================================================================
EOF
[ "$verdict" = PASS ]
