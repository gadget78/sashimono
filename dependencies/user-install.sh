#!/bin/bash
# Sashimono contract instance user installation script.
# This is intended to be called by Sashimono agent.
version=2.9984

# todo -
# - separate the domain_ssl_update file ?

cpu=$1
memory=$2
swapmem=$3
disk=$4
contract_dir=$5
contract_uid=$6
contract_gid=$7
peer_port=$8
user_port=$9
gp_tcp_port_start=${10}
gp_udp_port_start=${11}
docker_image=${12}
docker_registry=${13}
outbound_ipv6=${14}
outbound_net_interface=${15}

if [ -z "$cpu" ] || [ -z "$memory" ] || [ -z "$swapmem" ] || [ -z "$disk" ] || [ -z "$contract_dir" ] ||
    [ -z "$contract_uid" ] || [ -z "$contract_gid" ] || [ -z "$peer_port" ] || [ -z "$user_port" ] || [ -z "$gp_udp_port_start" ] || [ -z "$gp_tcp_port_start" ] ||
    [ -z "$docker_image" ] || [ -z "$docker_registry" ] || [ -z "$outbound_ipv6" ] || [ -z "$outbound_net_interface" ]; then
    echo "INVALID_PARAMS,INST_ERR" && exit 1
fi

prefix="sashi"
suffix=$(date +%s%N) # Epoch nanoseconds
user="$prefix$suffix"
contract_user="$user-secuser"
group="sashiuser"
cgroupsuffix="-cg"
user_dir=/home/$user
script_dir=$(dirname "$(realpath "$0")")
docker_bin=$script_dir/dockerbin
docker_img_dir=$docker_bin/images
docker_service="docker.service"
docker_pull_timeout_secs=900
cleanup_script=$user_dir/uninstall_cleanup.sh
gp_udp_port_count=2
gp_tcp_port_count=2
osversion=$(grep -ioP '^VERSION_ID=\K.+' /etc/os-release)

SA_CONFIG="/etc/sashimono/sa.cfg"
MBXRPL_CONFIG="/etc/sashimono/mb-xrpl/mb-xrpl.cfg"
EVERNODE_HOSTNAME=$(jq -r ".hp.host_address  // empty" "$SA_CONFIG")
XAHAU_URL=$(jq -r ".xrpl.rippledServer // empty" "$MBXRPL_CONFIG")
XAHAU_NODE=$(sed -E 's#^[a-z]+://##; s#[/:].*##' <<< "$XAHAU_URL")
EVRPANEL_JSON=$(jq -r ".evrpanel // empty" "$MBXRPL_CONFIG")
TLS_TYPE=$(jq -r ".proxy.tls_type  // empty" "$MBXRPL_CONFIG")
BLOCK_REP_PULL=$(jq -r ".host.blockRepPull  // empty" "$MBXRPL_CONFIG")
BLOCK_ALL_PULL=$(jq -r ".host.blockAllPull  // empty" "$MBXRPL_CONFIG")
REPUTATION_IMAGE=$(grep -o 'INSTANCE_IMAGE:"[^"]*"' /usr/bin/sashimono/reputationd/index.js | cut -d'"' -f2)

DNS_RESOLVER=$(jq -r ".proxy.dns_resolver | select( . != null )" "$MBXRPL_CONFIG")
if [[ -n "$DNS_RESOLVER" ]] && [[ ! "$DNS_RESOLVER" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    echo "Ignoring invalid proxy.dns_resolver value '$DNS_RESOLVER', using the default."
    DNS_RESOLVER=""
fi
NAMESERVER_OVERRIDE=${DNS_RESOLVER:-8.8.8.8}


# configured urls
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/v5.0.1/docker-compose-linux-x86_64"
DOCKER_AUTH_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:"
DOCKER_REGISTRY_URL="https://registry-1.docker.io/v2/"
CRANE_TAR_URL="https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz"
ACME_SH_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
ACME_DNS_PLUGIN_URL="https://gadget78.uk/dns_evernode.sh"

# Check if users already exists.
[ "$(id -u "$user" 2>/dev/null || echo -1)" -ge 0 ] && echo "HAS_USER,INST_ERR" && exit 1

# catch errors
set -Eeu
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap EXIT
function error_handler() {
    local exit_code="$?"
    local line_number="$1"
    local command="$2"
    echo "Rolling back user installation."
    "$script_dir"/user-uninstall.sh "$user" && echo "Rolled back the installation." || echo "failed to rollback $user"
    local error_message="ERROR SETTING UP DOCKER while executing command /"$command/" at line number $line_number, CAUGHT_ERR"
    echo -e "\n$error_message\n" | jq -Rs . && exit 1
}

function rollback() {
    echo "Rolling back user installation. $1"
    "$script_dir"/user-uninstall.sh "$user"
    echo "Rolled back the installation."
    echo "$1,INST_ERR" && exit 1
}

# Waits until a service becomes ready up to 3 seconds.
function service_ready() {
    local svcstat=""
    for ((i = 0; i < 30; i++)); do
        sleep 0.1
        svcstat=$(sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user is-active $1)
        if [ "$svcstat" == "active" ]; then
            return 0 # Success
        fi
    done
    return 1 # Error
}

# Wait until daemon ready
function wait_for_dockerd() {
    # Retry for 5 times until dockerd is available.
    local i=0
    while true; do
        DOCKER_HOST=$dockerd_socket $docker_bin/docker version >/dev/null && return 0 # Success
        ((i++))
        echo "Docker daemon isn't available. Retrying $i..."
        [[ $i -ge 5 ]] && return 1 # Error
        sleep 1
    done
}

function dockerd_in_user_slice() {
    local pid=$(pgrep -u "$user" -x dockerd | head -1)
    [ -z "$pid" ] && echo "Could not find the dockerd process of $user." && return 1
    local cgroups
    cgroups=$(cat /proc/$pid/cgroup) || return 1

    local slice_path="/user.slice/user-$user_id.slice"
    local controller path
    for controller in cpu memory; do
        path=$(awk -F: -v c="$controller" '{ n = split($2, ctrls, ","); for (i = 1; i <= n; i++) if (ctrls[i] == c) { print $3; exit } }' <<<"$cgroups")
        [ -z "$path" ] && path=$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' <<<"$cgroups")
        if [[ "$path" != "$slice_path" && "$path" != "$slice_path/"* ]]; then
            echo "dockerd of $user is in the $controller cgroup '$path', which is outside $slice_path."
            return 1
        fi
    done
    return 0
}

# check if image is within hosts blocklist
mapfile -t IMAGE_BLOCK_LIST < <(jq -r '.host.imageBlockList // [] | .[] | select(length > 0)' "$MBXRPL_CONFIG")
for pattern in "${IMAGE_BLOCK_LIST[@]}"; do
  if [[ "$docker_image" == "$pattern"* ]]; then
    [[ -z "$pattern" ]] && continue
    echo "image is blocklisted: $pattern"
    rollback "IMAGE_IS_BLOCKLISTED"
  fi
done

nofile_soft_limit=$(ulimit -n -S)
if [ $nofile_soft_limit -lt 250000 ]; then 
    ulimit -n 250000
    nofile_soft_limit=250000    
fi
max_instance_count=$(jq -r ".system.max_instance_count | select( . != null )" "$SA_CONFIG")
if [ -n "$max_instance_count" ] && [ "$max_instance_count" -gt 0 ]; then
    nofile_soft_limit=$((nofile_soft_limit / ( max_instance_count + 1 )))
    echo "setting ulimit -n to $nofile_soft_limit"
else
    echo "Error: max_instance_count is not valid or not found in $SA_CONFIG, defaulting ulimit to 55000"
    nofile_soft_limit=55000
fi
nproc_soft_limit=$(ulimit -u -S)

# Adding process and file descriptor limitations for the user before user creation
echo "$user hard nofile $nofile_soft_limit" | tee -a /etc/security/limits.conf
echo "$user soft nofile $nofile_soft_limit" | tee -a /etc/security/limits.conf
echo "$user hard nproc $nproc_soft_limit" | tee -a /etc/security/limits.conf

# Setup user and dockerd service.
useradd --shell /usr/sbin/nologin -m $user
usermod --lock $user
usermod -a -G $group $user
user_id=$(id -u "$user")
user_runtime_dir="/run/user/$user_id"
dockerd_socket="unix://$user_runtime_dir/docker.sock"



# In the Sashimono configuration, CPU time is 1000000us Sashimono is given max_cpu_us out of it.
# Instance allocation is multiplied by number of cores to determined the number of cores per instance and devided by 10 since cfs_period_us is set to 100000us
echo "Setting up user slice resources."

cores=$(grep -c ^processor /proc/cpuinfo)
cpu_period=1000000
cpu_quota=$(expr $(expr $cores \* $cpu \* 100 \/ $cpu_period))
[ $cpu_quota -lt 1 ] && cpu_quota=1 

swap_only_mem=$((swapmem - memory))
[ $swap_only_mem -lt 0 ] && swap_only_mem=0

# Resource limiting for the unprivileged user, with both cgroup v1 and v2.
mkdir -p /etc/systemd/system/user-$user_id.slice.d
echo "[Slice]
MemoryAccounting=true
CPUAccounting=true
MemoryMax=${memory}K
CPUQuota=${cpu_quota}%
MemorySwapMax=${swap_only_mem}K" | sudo tee /etc/systemd/system/user-$user_id.slice.d/override.conf || true
systemctl daemon-reload || rollback "SLICE_ERR"

loginctl enable-linger $user # Enable lingering to support rootless dockerd service installation.
chmod o-rwx "$user_dir"
echo "Created '$user' user."


# Creating a secondary user for the contract.
# This is the respective host user for the child user of the sashimono user inside docker container.
# Taking the uid and gid offsets.
uoffset=$(grep "^$user:[0-9]\+:[0-9]\+$" /etc/subuid | cut -d: -f2)
[ -z $uoffset ] && rollback "SUBUID_ERR"
contract_host_uid=$(expr $uoffset + $contract_uid - 1)

# If contract gid is not 0, get the calculated host gid and create the contract user group
# and create user inside both contract user group and sashimono user group.
# Otherwise get sashimono user's gid and create contract user inside that group.
# Even though there's this "if not 0" condition, contract_gid will always be 0 since we are setting hp config's gid to 0 in instance creation.
if [ ! $contract_gid -eq 0 ]; then
    goffset=$(grep "^$user:[0-9]\+:[0-9]\+$" /etc/subgid | cut -d: -f2)
    [ -z $goffset ] && rollback "SUBGID_ERR"
    contract_host_gid=$(expr $goffset + $contract_gid - 1)
    groupadd -g "$contract_host_gid" "$contract_user"
    useradd --shell /usr/sbin/nologin -M -g "$contract_host_gid" -G "$user" -u "$contract_host_uid" "$contract_user"
else
    contract_host_gid=$(id -g "$user")
    useradd --shell /usr/sbin/nologin -M -g "$contract_host_gid" -u "$contract_host_uid" "$contract_user"
fi

usermod --lock "$contract_user"
echo "Created '$contract_user' contract user."


echo "checking quota system, and adding disk quota of $disk to the user $user"
if [[ "$(quotaon -p / | grep user | awk '{print $7}')" == "off" ]]; then
    echo "User quota found not enabled, enabling user quota system..."
            
    # Check if supporting Quota kernel modules are installed
    modprobe quota_v2 2>/dev/null || {
        echo "Quota kernel modules not available → installing missing kernel extras"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            linux-image-extra-virtual \
            linux-modules-extra-$(uname -r)
    }

    {
        # Do nothing at all if there is no real root (/) entry yet
        if ! grep -qE '^[[:space:]]*[^#][^#]*[[:space:]]+/[[:space:]]' /etc/fstab; then
            echo "/etc/fstab has no root filesystem entry yet → skipping usrquota addition"
            true
        elif grep -qE '^[[:space:]]*[^#].*\s+/\s+.*\busrquota\b' /etc/fstab; then
            echo "usrquota already present on root filesystem → no fstab changes needed"
            true
        else
            # Backup first
            BACKUP="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
            cp /etc/fstab "$BACKUP"

            # Remove any old quota options (old-style and journaled)
            sed -i -E '/^[^#]*\s+\/\s+/ {
                s/,?grpjquota=[^,[:space:]]*//g
                s/,?usrjquota=[^,[:space:]]*//g
                s/,?jqfmt=[^,[:space:]]*//g
                s/,?usrquota[^,[:space:]]*//g
                s/,?grpquota[^,[:space:]]*//g
                s/,?quota[^,[:space:]]*//g
                s/remount-ro[^,[:space:]]*/remount-ro/g
                s/,,+/,/g
                s/(\s+)([^,\s]+),/\1\2/
            }' /etc/fstab

            # Add usrquota (only if it really wasn’t there yet – double safety)
            sed -i -E '/^[^#]*\s+\/\s+/ {s/(\s+\S+)(\s+[0-9]+\s+[0-9]+\s*)$/\1,usrquota\2/}' /etc/fstab

            echo "Successfully added usrquota to root entry in /etc/fstab"
            true
        fi
    } || {
        [ -n "${BACKUP:-}" ] && cp "$BACKUP" /etc/fstab && rm -f "$BACKUP"
        echo "Quota addition failed or was skipped → all changes rolled back"
        mount -o remount / 2>/dev/null || true
    }

    {
        if ! grep -q ",usrquota" /etc/fstab; then
            # Backup fstab 1st
            BACKUP="/etc/fstab.backup.$(date +%Y%m%d_%H%M%S)"
            cp /etc/fstab "$BACKUP"
            # First remove any existing quota options
            sed -i -E '/^[^#]*\s+\/\s+/ {
                s/,?grpjquota=[^,[:space:]]*//g
                s/,?usrjquota=[^,[:space:]]*//g
                s/,?jqfmt=[^,[:space:]]*//g
                s/,?usrquota[^,[:space:]]*//g
                s/,?grpquota[^,[:space:]]*//g
                s/,?quota[^,[:space:]]*//g
                s/remount-ro[^,[:space:]]*/remount-ro/g
                s/,,+/,/g
                s/(\s+)([^,\s]+),/\1\2/
            }' /etc/fstab
            # then add just usrquota entry
            sed -i -E '/^[^#]*\s+\/\s+/ {s/(\s+\S+)(\s+[0-9]+\s+[0-9]+\s*)$/\1,usrquota\2/}' /etc/fstab
        fi
    } || {
        echo "Failed - rolling back..."
        cp "$BACKUP" /etc/fstab
        mount -o remount / 2>/dev/null || true
    }

    {
        ROOT_MOUNT=$(findmnt -n -o TARGET /)
        quotaoff "$ROOT_MOUNT" 2>/dev/null || true
        rm -f "$ROOT_MOUNT"/quota.* "$ROOT_MOUNT"/aquota.* 2>/dev/null || true
        sync && systemctl daemon-reload && mount -o remount "$ROOT_MOUNT"
        quotacheck -cum "$ROOT_MOUNT" && quotaon -u "$ROOT_MOUNT"
        quotaon -p "$ROOT_MOUNT" | grep user
    } || {
        echo "something failed when setting up user quota system..."
    }
fi
setquota -u "$user" "$disk" "$disk" 0 0 / && echo "Configured disk quota of $disk for the user $user" || echo "Configuring disk quota failed"

# # download/copy over docker compose plugin
# mkdir -p $user_dir/.docker/cli-plugins
# if [ ! -f "${docker_bin}/docker-compose" ]; then
#     curl -SL $DOCKER_COMPOSE_URL -o ${docker_bin}/docker-compose
# fi
# cp ${docker_bin}/docker-compose $user_dir/.docker/cli-plugins/docker-compose
# chown -R $user:$user $user_dir/.docker/
# chmod +x $user_dir/.docker/cli-plugins/docker-compose

# Create authz plugin
sudo -u $user mkdir -p $user_dir/.local/lib/docker/plugins/authz
sudo -u $user cat > $user_dir/.local/lib/docker/plugins/authz/authz.py <<EOF
#!/usr/bin/env python3
#authz.py

import datetime
import json
import os
from socket import socket, AF_UNIX, SOCK_STREAM
from socketserver import ThreadingMixIn
from socketserver import UnixStreamServer
from http.server import BaseHTTPRequestHandler
from http.client import HTTPConnection

SOCKET_PATH = '${user_dir}/.local/lib/docker/plugins/authz.sock'
DOCKER_SOCK = '${user_runtime_dir}/docker.sock'
ts = datetime.datetime.now().isoformat()
count = 1

if os.path.exists(SOCKET_PATH):
    os.remove(SOCKET_PATH)

class ThreadedUnixStreamServer(ThreadingMixIn, UnixStreamServer):
    pass

class AuthZHandler(BaseHTTPRequestHandler):
    def address_string(self): return "local"
    def log_message(self, f, *a): pass

    @staticmethod
    def is_autolock_enabled():
        try:
            conn = HTTPConnection('localhost')
            conn.sock = socket(AF_UNIX, SOCK_STREAM)
            conn.sock.connect(DOCKER_SOCK)
            conn.request('GET', '/swarm')
            resp = conn.getresponse()
            if resp.status != 200:
                return False
            data = json.loads(resp.read().decode())
            conn.close()
            return data.get('Spec', {}).get('EncryptionConfig', {}).get('AutoLockManagers', False)
        except Exception as e:
            print(f"[conn failed] {type(e).__name__}: {e}", flush=True)
            return False

    def do_POST(self):
        global count
        deny = False
        if self.path == '/Plugin.Activate':
            print(f"🟢 [ALLOW] [{ts}] [PLUGIN] Active checkup", flush=True)
            return self._json(200, {"Implements": ["authz"]})
        if self.path == '/AuthZPlugin.AuthZRes':
            return self._json(200, {"Allow": True})
        if self.path != '/AuthZPlugin.AuthZReq':
            self.send_response(404); self.end_headers(); return

        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length)) if length else {}
        m = body.get('RequestMethod', '')
        u = body.get('RequestUri', '')

        if ('/swarm' in u and '/swarm/' not in u and count <= 3) or ('/swarm/init' in u) or ('/swarm/unlock' in u and '/swarm/unlockkey' not in u and count <= 3) or ('/swarm/unlockkey' in u and self.is_autolock_enabled()):
            print(f"🟢 [ALLOW] [{ts}] [PLUGIN] [Count {count} of 3] {m} {u}", flush=True)
            count += 1
            return self._json(200, {"Allow": True})
        else:
            deny = any(x in u for x in ['/exec', '/attach', '/archive', '/swarm'])

        print(f"{'❌ [DENY]' if deny else '🟢 [ALLOW]'} [{ts}] {m} {u}", flush=True)
        return self._json(200, {"Allow": not deny, "Msg": "permission denied" if deny else None})

    def _json(self, code, data):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

if __name__ == '__main__':
    server = ThreadedUnixStreamServer(SOCKET_PATH, AuthZHandler)
    os.chmod(SOCKET_PATH, 0o666)
    print(f"✅ [{ts}] AuthZ plugin running (listening on {SOCKET_PATH})", flush=True)
    server.serve_forever()
EOF
chmod a-w,+x $user_dir/.local/lib/docker/plugins/authz/authz.py
sudo -u $user echo "unix://$user_dir/.local/lib/docker/plugins/authz.sock" > $user_dir/.local/lib/docker/plugins/authz.spec
sudo -u $user touch $user_dir/.local/lib/docker/plugins/authz/authz.log

# Extract additional settings if present, replaces all -- with |, and use that string to create an array
echo
echo "# checking for any additional config elements within image name $docker_image"
IFS='|' read -r -a image_array <<< "$(echo $docker_image | sed 's/--/|/g' | cut -d'|' -f2-)"

echo "captured additional docker settings, ${image_array[@]}"
custom_docker_settings=false
custom_docker_domain=""
custom_docker_subdomain=""
custom_docker_domain_ssl="true"
custom_docker_domain_scheme="https"
custom_docker_domain_dns="dns"
internal_peer_port="$peer_port"
internal_user_port="$user_port"
internal_gptcp1_port="$gp_tcp_port_start"
internal_gpudp1_port="$gp_udp_port_start"
internal_gptcp2_port=$((gp_tcp_port_start + 1))
internal_gpudp2_port=$((gp_udp_port_start + 1))
internal_run_contract=""
internal_env_count=0
internal_dev_count=0
internal_dev_values=()
internal_sec_count=4
internal_sec_values=("user" "pass" "url" "key")
internal_vol_count=0
internal_vol_values=()
internal_readonly="false"
internal_block_exploits="1"
internal_security="low"
internal_security_api="https://$EVERNODE_HOSTNAME/api-swarmunlock"

# Loop through the array to extract pairs
for ((i = 0; i < ${#image_array[@]}; i += 2)); do
    image_array_name="${image_array[i]}"
    [[ $(( i + 1 )) -lt ${#image_array[@]} ]] && image_array_value="${image_array[i + 1]}" || image_array_value=""
    echo "found additional setting, name: \"$image_array_name\"    value: \"$image_array_value\""
    if [[ -n "$image_array_name" ]]; then
        if [[ "$image_array_name" == "domain" ]]; then
            custom_docker_settings="true"
            custom_docker_domain=$image_array_value
        fi
        if [[ "$image_array_name" == "subdomain" ]]; then
            custom_docker_settings="true"
            custom_docker_subdomain=$image_array_value
        fi
        if [[ "$image_array_name" == "ssl" ]]; then
            custom_docker_settings="true"
            if [[ "$image_array_value" == "false" ]];then custom_docker_domain_ssl="false"; fi
        fi
        if [[ "$image_array_name" == "proxyssl" ]]; then
            custom_docker_settings="true"
            if [[ "$image_array_value" == "false" ]];then custom_docker_domain_scheme="http"; fi
        fi
        if [[ "$image_array_name" == "dns" ]]; then
            custom_docker_settings="true"
            custom_docker_domain_dns=$image_array_value
        fi
        if [[ "$image_array_name" == "peer" ]]; then
            custom_docker_settings="true"
            internal_peer_port=$image_array_value
        fi
        if [[ "$image_array_name" == "user" ]]; then
            custom_docker_settings="true"
            internal_user_port=$image_array_value
        fi
        if [[ "$image_array_name" == "gptcp1" ]]; then
            custom_docker_settings="true"
            internal_gptcp1_port=$image_array_value
        fi
        if [[ "$image_array_name" == "gpudp1" ]]; then
            custom_docker_settings="true"
            internal_gpudp1_port=$image_array_value
        fi
        if [[ "$image_array_name" == "gptcp2" ]]; then
            custom_docker_settings="true"
            internal_gptcp2_port=$image_array_value
        fi
        if [[ "$image_array_name" == "gpudp2" ]]; then
            custom_docker_settings="true"
            internal_gpudp2_port=$image_array_value
        fi
        if [[ "$image_array_name" == "contract" ]]; then
            if [ "$image_array_value" == "true" ]; then
                custom_docker_settings="true"
                internal_run_contract="run /contract"
                echo "found contract command, enabling \"run /contract\""
            else
                custom_docker_settings="true"
                processed_contract_value=$(echo "${image_array_value#*-}" | sed 's|\.\.\.|\$|g; s|\.\.|-|g; s|___|\/|g; s|__| |g;')
                internal_run_contract=${processed_contract_value}
                echo "found contract command, setting run command as ${internal_run_contract}"
            fi
        fi
        if [[ "$image_array_name" == "readonly" ]]; then
            if [ "$image_array_value" == "true" ]; then
                custom_docker_settings="true"
                internal_readonly="true"
                echo "found read only setting, setting docker image to read only"
            fi
        fi
        if [[ "$image_array_name" == "crowdsec" ]]; then
            if [ "$image_array_value" == "false" ]; then
                custom_docker_settings="true"
                internal_block_exploits="0"
                echo "found block_exploits setting, switching off proxy host block-exploits(mod-security)"
            fi
        fi
        if [[ "$image_array_name" == "security" ]] || [[ "$image_array_name" == "sec" ]]; then
            custom_docker_settings="true"
            if [[ $image_array_value =~ ^(none|low|mid|high)$ ]]; then
                internal_security="$image_array_value"
            else
                internal_security="mid"
            fi
            echo "✅ [INFO] found custom security setting, setting security level to, $internal_security" | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
        fi
        if [[ "$image_array_name" == "securityapi" ]]; then
            processed_api_value=$(echo "${image_array_value#*-}" | sed 's|\.\.\.|\$|g; s|\.\.|-|g; s|___|\/|g; s|__| |g;')
            if [[ -n "$processed_api_value" ]] && [[ $(echo "$processed_api_value" | tr -cd '.' | wc -c) -gt 1 ]]; then
                custom_docker_settings="true"
                if [[ "$processed_api_value" != http* ]]; then processed_api_value="https://$processed_api_value"; fi
                internal_security_api="$processed_api_value"
                if curl -f -k -s -m 25 "$internal_security_api" | jq -r '.' 2>&1 | openssl pkey -pubin -noout >/dev/null 2>&1; then
                    internal_security="mid"
                else
                    internal_security="low"
                fi
                echo "✅ [INFO] found and checked custom security API $internal_security_api, setting security level at $internal_security (if API check passed, this is set to mid)" | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
            fi
        fi
        if [[ "$image_array_name" == "env"[0-9]* ]]; then
            custom_docker_settings="true"
            internal_env_count=$((internal_env_count + 1))
            env_key_name_set="internal_env${internal_env_count}_key"
            printf -v "$env_key_name_set" "$(echo "$image_array_value" | cut -d'-' -f1)"
            env_value_name_set="internal_env${internal_env_count}_value"
            processed_env_value=$(echo "${image_array_value#*-}" | sed 's|\.\.\.|\$|g; s|\.\.|-|g; s|___|\/|g; s|__| |g;')
            printf -v "$env_value_name_set" "$processed_env_value"
            echo "found environment entry, number $internal_env_count, key>${!env_key_name_set} value>${!env_value_name_set}"
        fi
        if [[ "$image_array_name" == "dev"[0-9]* ]]; then
            custom_docker_settings="true"
            internal_dev_count=$((internal_dev_count + 1))
            processed_dev_value=$(echo "$image_array_value" | sed 's|\.\.\.|\$|g; s|\.\.|-|g; s|___|\/|g; s|__| |g;')
            internal_dev_values+=("$processed_dev_value")
            echo "found device entry, number $internal_dev_count, value>${processed_dev_value}"
        fi
        if [[ "$image_array_name" == "sec"[0-9]* ]]; then
            custom_docker_settings="true"
            internal_sec_count=$((internal_sec_count + 1))
            processed_sec_value=$(echo "$image_array_value" | sed 's|\.\.\.|\$|g; s|\.\.|-|g; s|___|\/|g; s|__| |g;')
            internal_sec_values+=("$processed_sec_value")
            echo "found secret entry, number $internal_sec_count, value>${processed_sec_value}"
        fi
        if [[ "$image_array_name" == "vol"[0-9]* ]]; then
            custom_docker_settings="true"
            internal_vol_count=$((internal_vol_count + 1))
            processed_vol_value=$(echo "$image_array_value" | sed 's|\.\.\.|\$|g; s|\.\.|-|g; s|___|\/|g; s|__| |g;')
            internal_vol_values+=("$processed_vol_value")
            echo "found volume entry, number $internal_vol_count, value>${processed_vol_value}"
        fi
    fi
done

if [[ "$internal_security" = "low" ]]; then
    if ( curl -f -k -s -m 25 "$internal_security_api" | jq -r '.' 2>&1 | openssl pkey -pubin -noout >/dev/null 2>&1); then
        internal_security="mid"
        echo "✅ [INFO] auto security level setting is on $internal_security as default API endpoint test passed, endpoint $internal_security_api" | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
    else
        echo "✅ [INFO] auto security level setting is on $internal_security, due to no workng API at $internal_security_api" | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
    fi
fi

# setup up docker_pull_image, and docker_image_version
if [[ "$docker_image" != *":"* ]]; then
    docker_image_version="latest"
    docker_pull_image=$(echo $docker_image | sed 's/--/|/g' | cut -d'|' -f1)
    echo "all additional port/custom settings found and saved, will be using a pull image of $docker_pull_image, with version defaulted to latest"
else
    docker_image_version="$(echo $docker_image | cut -d':' -f2 | sed 's/--/|/g' | cut -d'|' -f1)"
    docker_pull_image="$(echo "$docker_image" | cut -d':' -f1):${docker_image_version}"
    echo "all additional port/custom settings found and saved, will be using a pull image of $docker_pull_image, version tag of $docker_image_version"
fi
echo

# Setup env variables for the user.
echo "
export XDG_RUNTIME_DIR=$user_runtime_dir
export PATH=$docker_bin:\$PATH
export DOCKER_HOST=$dockerd_socket
[ -f \"/contract/env.vars\" ] && source /contract/env.vars
[ -f \"$user_dir/$contract_dir/env.vars\" ] && source $user_dir/$contract_dir/env.vars"  >>"$user_dir"/.bashrc
echo "Updated user .bashrc."

# Wait until user systemd is functioning.
user_systemd=""
for ((i = 0; i < 30; i++)); do
    sleep 0.1
    user_systemd=$(sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user is-system-running 2>/dev/null) || true
    [ "$user_systemd" == "running" ] && break
done
[ "$user_systemd" != "running" ] && rollback "NO_SYSTEMD"


# adding ports to ufw (so they clear if its been enabled.)
echo "Allowing user and peer ports in ufw firewall"
rule_list=$(sudo ufw status)
comment=$prefix-$contract_dir

sudo ufw allow "${user_port}" comment "${comment}-user" || echo "WARNING: failed to add firewall rule for port ${user_port}"
sudo ufw allow "${peer_port}" comment "${comment}-peer" || echo "WARNING: failed to add firewall rule for port ${peer_port}"

# udp
for ((i = 0; i < gp_udp_port_count; i++)); do
    gp_udp_port=$((gp_udp_port_start + i))
    if grep -qE "^${gp_udp_port}/udp[[:space:]]+ALLOW" <<< "$rule_list"; then
        echo "General purpose UDP port ${gp_udp_port} rule already exists. Skipping."
    else
        gp_udp_port_comment="${comment}-gp-udp-${i}"
        echo "Adding new rule to allow general purpose UDP port ${gp_udp_port} from firewall."
        sudo ufw allow "${gp_udp_port}/udp" comment "${gp_udp_port_comment}" || echo "WARNING: failed to add firewall rule for port ${gp_udp_port}"
    fi
done

# tcp
for ((i = 0; i < gp_tcp_port_count; i++)); do
    gp_tcp_port=$((gp_tcp_port_start + i))
    if grep -qE "^${gp_tcp_port}/tcp[[:space:]]+ALLOW" <<< "$rule_list"; then
        echo "General purpose TCP port ${gp_tcp_port} rule already exists. Skipping."
    else
        gp_tcp_port_comment="${comment}-gp-tcp-${i}"
        echo "Adding new rule to allow general purpose TCP port ${gp_tcp_port} from firewall."
        sudo ufw allow "${gp_tcp_port}/tcp" comment "${gp_tcp_port_comment}" || echo "WARNING: failed to add firewall rule for port ${gp_tcp_port}"
    fi
done


# Creating AppArmor Profile for unpriviledged user on Ubuntu 24.04
if [ "$osversion" == "24.04" ]; then
    filename=$(echo /home/$user/bin/rootlesskit | sed -e s@^/@@ -e s@/@.@g)
    cat <<EOF > /etc/apparmor.d/$filename
abi <abi/4.0>,
include <tunables/global>

"/home/$user/bin/rootlesskit" flags=(unconfined) {
  userns,

  include if exists <local/$filename>
}
EOF
    chown $user:$user /etc/apparmor.d/$filename
    systemctl restart apparmor.service
fi


# install rootless docker
echo "Installing rootless dockerd for user."
sudo -H -u "$user" PATH="$docker_bin":"$PATH" XDG_RUNTIME_DIR="$user_runtime_dir" "$docker_bin"/dockerd-rootless-setuptool.sh install


# Add environment variables as an override to docker service unit file.
echo "Applying $docker_service env overrides."
docker_service_override_conf="$user_dir/.config/systemd/user/$docker_service.d/override.conf"
sudo -H -u "$user" mkdir $user_dir/.config/systemd/user/$docker_service.d
sudo -H -u "$user" touch $docker_service_override_conf
echo "[Service]
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns
" >"$docker_service_override_conf"

# check nftables is installed (TODO: add this check to the main evernode installer)
if ! command -v nft &> /dev/null; then
    echo "nftables not installed. Installing now..."
    apt-get update && apt-get -y install nftables
fi

# Create nftables (aka iptables), to block traffic to the local LAN subnet (for IPv4 and IPv6), and adding in exceptions.
local_ip=$(hostname -I | awk '{print $1}' | xargs) 
public_hostname_ip=$(dig +short "$EVERNODE_HOSTNAME" | head -n 1 | xargs)
if [[ "$local_ip" != "$public_hostname_ip" ]]; then
    nft flush table ip docker_filter_$user_id 2>/dev/null || true
    nft delete table ip docker_filter_$user_id 2>/dev/null || true
    nft add table ip docker_filter_$user_id
    nft add chain ip docker_filter_$user_id OUTPUT '{ type filter hook output priority 100 ; policy accept ; }'
    nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ct state established,related accept

    nft add chain ip docker_filter_$user_id INPUT '{ type filter hook input priority 100 ; policy accept ; }'
    nft add rule ip docker_filter_$user_id INPUT ct state established,related accept

    nft add chain ip docker_filter_$user_id FORWARD '{ type filter hook forward priority 100 ; policy accept ; }'
    nft add rule ip docker_filter_$user_id FORWARD ct state established,related accept


    echo "detected local ip to $local_ip, allowing."
    nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ip daddr $local_ip accept

    gateway=$(ip route show | grep default | awk '{print $3}')
    if [ -z "$gateway" ]; then
        echo "Warning: Could not detect gateway IP."
    else
        echo "detected gateway as $gateway, allowing."
        nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ip daddr $gateway accept
    fi

    proxy_ip=$(jq -r ".proxy.ip | select( . != null )" "$MBXRPL_CONFIG" )
    if [ -z "$proxy_ip" ]; then proxy_ip=$(jq -r ".proxy.npm_url | select( . != null )" "$MBXRPL_CONFIG" | awk -F[/:] '{print $4}'); fi
    if [ -z "$proxy_ip" ]; then
        echo "Warning: Could not retrieve proxy IP."
    else

        echo "detected proxy ip to $proxy_ip, allowing"
        nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ct state established,related accept
        nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ip daddr $proxy_ip accept
        nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ip protocol udp accept

        iface=$(ip -4 route get "$proxy_ip" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        ip neigh flush to "$proxy_ip" 2>/dev/null     # so a recreated proxy CT can't leave a stale MAC behind
        ping -c1 -W1 "$proxy_ip" >/dev/null 2>&1
        proxy_mac=$(ip neigh show "$proxy_ip" dev "$iface" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit}}')

        if [ -z "$iface" ] || [ -z "$proxy_mac" ]; then
            echo "ERROR: could not resolve interface/MAC for $proxy_ip, is the proxy up? dscp_steer left unchanged"
        else
            nft_table=$(nft list table netdev dscp_steer 2>/dev/null || true)
            if [[ "$nft_table" == *"$iface"* && "$nft_table" == *"$proxy_mac"* ]] && nft list table ip dscp_ct &>/dev/null; then
                echo "dscp_steer already in place ($iface -> $proxy_mac), no need to re-apply."
            else
                dscp_mark="7"
                nft_rules="
                    add table netdev dscp_steer
                    delete table netdev dscp_steer
                    table netdev dscp_steer {
                        chain out {
                            type filter hook egress device $iface priority 0; policy accept;
                            ether type ip ip dscp $dscp_mark counter ether daddr set $proxy_mac
                        }
                    }
                    add table ip dscp_ct
                    delete table ip dscp_ct
                    table ip dscp_ct {
                        chain pre {
                            type filter hook prerouting priority mangle; policy accept;
                            ip dscp $dscp_mark ct mark set $dscp_mark
                        }
                        chain post {
                            type filter hook postrouting priority mangle; policy accept;
                            ct mark $dscp_mark ip dscp set $dscp_mark
                        }
                    }
                "
                nft -f - <<< "$nft_rules" && echo "applied dscp_steer ($iface -> $proxy_mac)" || echo "ERROR: failed to apply dscp_steer"
            fi
        fi

    fi

    lan_subnet=$(ip route | grep -oP '(\d+\.\d+\.\d+\.\d+/\d+)' | head -n 1)
    if [ -z "$lan_subnet" ]; then
        echo "Error: Could not detect LAN subnet."
    else
        local_dns=$(grep '^nameserver' /etc/resolv.conf | awk 'NR==1 {print $2}')
        if [ -z "$local_dns" ]; then
            echo "Warning: Could not detect local DNS IP."
        else
            if [ "$(echo "$local_dns" | cut -d'.' -f1-2)" = "$(echo "$lan_subnet" | cut -d'.' -f1-2)" ]; then
                echo "detected local DNS IP as $local_dns, allowing. (as within the lan subnet of $lan_subnet)"
                nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ip daddr $local_dns accept
            else
                echo "detected local DNS IP as $local_dns, not part of lan subnet of $lan_subnet"
            fi
        fi
        echo "detected lan subnet ip to $lan_subnet, blocking/dropping"
        nft add rule ip docker_filter_$user_id OUTPUT meta skuid $user_id ip daddr $lan_subnet drop
    fi
else
    echo "a stand alone evernode with no subnet detected, no extra ip table rules needed"
fi

# We need to enable ipv6 configurations if outbound ipv6 address is specified.
if [ "$outbound_ipv6" != "-" ] && [ "$outbound_net_interface" != "-" ]; then
    echo "ipv6 detected, adding dedicated settings to environment..."
    # Pass the relevant ipv6 parameters to rootlesskit flags. rootlesskit will in turn pass these to slirp4nets.
    # Also apply ipv6 route configuration patch in the dockerd process namespace (credits: https://github.com/containers/podman/issues/15850#issuecomment-1320028298)
    echo "
    Environment=\"DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=--ipv6 --outbound-addr6=$outbound_ipv6\"
    ExecStartPost=/bin/bash -c 'nsenter -U --preserve-credentials -n -t $""(pgrep -u $user dockerd) /bin/bash -c \"ip addr add fd00::100/64 dev tap0 && ip route add default via fd00::2 dev tap0\"'
    " >>$docker_service_override_conf

    # Set the predefined ipv6 parameters to docker daemon config.
    mkdir -p $user_dir/.config/docker
    echo "{
        \"experimental\": true,
        \"ipv6\": true,
        \"fixed-cidr-v6\": \"2001:db8:1::/64\",
        \"ip6tables\": true,
        \"mtu\": 65520
    }" >$user_dir/.config/docker/daemon.json

    # Add the outbound ipv6 address to the specified network interface.
    ip addr add $outbound_ipv6 dev $outbound_net_interface

    # add rules to iptables, to restrict access to ipv6 subnet
    if [[ "$local_ip" != "$public_hostname_ip" ]]; then
        ipv6_gateway=$(ip -6 route show | grep default | awk '{print $3}')
        nft add rule ip6 docker_filter_$user_id OUTPUT ip6 daddr "$ipv6_gateway" accept
        ipv6_subnet=$(ip -6 route show | grep -v default | grep -oP '([0-9a-f:]+/\d+)' | head -n 1)
        nft add rule ip6 docker_filter_$user_id OUTPUT ip6 daddr "$ipv6_subnet" drop
    fi

    # Add instructions to the cleanup script so the outbound ip assignment will be removed upon user uninstall.
    echo "ip addr del $outbound_ipv6 dev $outbound_net_interface" >>$cleanup_script
fi

# Overwrite docker-rootless cli args on the docker service unit file (ExecStart is not supported by override.conf).
docker_service_file="$user_dir/.config/systemd/user/$docker_service"
if [[ "$internal_security" == "mid" ]] || [[ "$internal_security" == "high" ]]; then 
    post_script='ExecStartPost=/bin/bash -c '\'' \
        log_file="'"${user_dir}"'/.local/lib/docker/plugins/authz/authz.log"; api_address=$(cat "'"${user_dir}"'/.local/share/docker/swarm/certificates/swmkey_apiAddress.txt" 2>/dev/null); api_encrypted_key=$(cat "'"${user_dir}"'/.local/share/docker/swarm/certificates/swmkey_apiKey.txt" 2>/dev/null); api_container=$(cat "'"${user_dir}"'/.local/share/docker/swarm/certificates/swmkey_apiContainer.txt" 2>/dev/null); json_data=$(printf "{\134\134\042encrypted_key\134\134\042:\134\134\042%%s\134\134\042,\134\134\042container_name\134\134\042:\134\134\042%%s\134\134\042}" "$api_encrypted_key" "$api_container"); \
        [[ ! -f "'"${user_dir}"'/.local/share/docker/swarm/certificates/swmkey_instanceKey.txt" ]] && { echo -e "\\U0001F7E2 [INFO] swarm unlock not needed on 1st setup/boot" | tee -a "$log_file" >&2; exit 0; }; \
        [[ -z "$api_address" ]] && [[ -z "$api_encrypted_key" ]] && { echo -e "\\U0000274C [ERROR] no API settings to unlock swarm. manual unlock needed." | tee -a "$log_file" >&2; exit 0; }; \
        sleep 5; decrypted_key=$(curl -s -f -X POST -H "Content-Type: application/json" -d "$json_data" "$api_address" 2>>"$log_file") || { echo -e "\\U0000274C [ERROR] API call to $api_address failed" | tee -a "$log_file" >&2; exit 0; }; \
        [[ -z "$decrypted_key" || ! "$decrypted_key" =~ ^SWMKEY-1 ]] && { echo -e "\\U0000274C [ERROR] Invalid key ( $decrypted_key ) ( $json_data )" | tee -a "$log_file" >&2; exit 0; }; \
        export DOCKER_HOST="unix://'"${user_runtime_dir}"'/docker.sock"; echo "$decrypted_key" | '"$docker_bin"'/docker swarm unlock 2>>"$log_file" || { echo -e "\\U0000274C [ERROR] Unlock failed using key ( key=$decrypted_key )" | tee -a "$log_file" >&2; exit 0; }; \
        echo -e "\\U00002705 [INFO] Docker Unlock Success via API route $api_address" | tee -a "$log_file" >&2; exit 0; '\'' '
    awk -v post="$post_script" '/^ExecStart=/ {print; print post; next} 1' "$docker_service_file" > "${docker_service_file}.tmp" && mv "${docker_service_file}.tmp" "${docker_service_file}"
fi
auth_py="$user_dir/.local/lib/docker/plugins/authz/authz.py"
auth_log="$user_dir/.local/lib/docker/plugins/authz/authz.log"
auth_flag="" && [[ "${internal_security:-low}" != "none" ]] && auth_flag="--authorization-plugin=authz"
private_dock_flag="" ## && [[ "${docker_registry:-}" != "-" ]] && private_dock_flag="--registry-mirror http://$docker_registry --insecure-registry $docker_registry"
new_exec='ExecStart=/bin/bash -c '\''python3 -u '"$user_dir"'/.local/lib/docker/plugins/authz/authz.py >> '"$user_dir"'/.local/lib/docker/plugins/authz/authz.log 2>&1 & sleep 5 && exec '"$docker_bin"'/dockerd-rootless.sh --max-concurrent-downloads 1 --experimental '"$private_dock_flag"' '"$auth_flag"' '\'' '
awk -v exec="$new_exec" '/^ExecStart=/ {print exec; next} {print}' "${docker_service_file}" > "${docker_service_file}.tmp" && mv "${docker_service_file}.tmp" "${docker_service_file}"
#sed -i "s#^ExecStart=.*\$#${escaped_exec}#" "${docker_service_file}"
chmod a-w ${docker_service_file}

# Reload the docker daemon and service.
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user daemon-reload
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user restart $docker_service
service_ready $docker_service || rollback "NO_DOCKERSVC"
# Wait until docker daemon ready, If failed rollback.
! wait_for_dockerd && rollback "NO_DOCKERD"
# Make sure the resource limits of the user slice apply to the instance.
dockerd_in_user_slice || rollback "CGROUP_ERR"
echo "finished Installing rootless dockerd."
echo
echo "_______________________________________"




registry_filter() {
  local full_image="$1"
  local first_segment="${full_image%%/*}"
  
  if [[ "$first_segment" == *"."* ]] || [[ "$first_segment" == *":"* ]]; then
    # Has registry prefix — strip it
    echo "repo.local/${full_image#*/}"
  else
    # No registry prefix (Docker Hub image)
    echo "repo.local/$full_image"
  fi
}

image_layer_filter() {
  local IMAGE_TAR="$1"
  local WORKDIR=$(mktemp -d)
  local CLEAN_TAR="${IMAGE_TAR%.tar}-clean.tar"
  local filtered=false

  echo "extracting image tar for filtering..."
  tar -xf "$IMAGE_TAR" -C "$WORKDIR"
  local CONFIG_FILE=$(jq -r '.[0].Config' "$WORKDIR/manifest.json")  || { echo " failed to find layer config file, this WILL cause issues!"; true; }
  echo "found config file: $CONFIG_FILE"

  # Collect all layers into array FIRST to avoid duplicate processing after rename
  mapfile -t LAYERS < <(find "$WORKDIR" -name "*.tar.gz")
  echo "found ${#LAYERS[@]} layer(s) to process"

  for layer in "${LAYERS[@]}"; do

    # Detect actual format from magic bytes, not extension
    if file "$layer" | grep -q "gzip"; then
      IS_GZIP=true
      LIST_CMD="tar -tzf"
      EXTRACT_CMD="tar -xzf"
      REPACK_CMD="tar -czf"
    else
      IS_GZIP=false
      LIST_CMD="tar -tf"
      EXTRACT_CMD="tar -xf"
      REPACK_CMD="tar -cf"
    fi

    # check layer for /dev/
    DEV_ENTRIES=$($LIST_CMD "$layer" 2>/dev/null | grep "^./dev/.\|^dev/." || true)
    if [ -n "$DEV_ENTRIES" ]; then
      echo "  found device entries, $DEV_ENTRIES in layer, :$(basename $layer) (compressed $IS_GZIP)"
      filtered=true
      local OLD_FILENAME=$(basename "$layer")
      local OLD_HASH=$(basename "$layer" .tar.gz)
      local CONFIG_PATH="$WORKDIR/$CONFIG_FILE"

      # Get layer index from manifest, then read OLD DiffID from config at that position
      # This is more reliable than calculating it, especially for uncompressed layers
      local LAYER_INDEX=$(jq -r --arg filename "$OLD_FILENAME" \
        '[.[0].Layers | to_entries[] | select(.value == $filename) | .key] | first' \
        "$WORKDIR/manifest.json")
      local OLD_DIFFID=$(jq -r --argjson idx "$LAYER_INDEX" \
        '.rootfs.diff_ids[$idx]' "$CONFIG_PATH" | sed 's/sha256://')
      echo "   Old DiffID (config pos $LAYER_INDEX): ${OLD_DIFFID:0:12}..."

      local LAYER_DIR=$(mktemp -d)

      $EXTRACT_CMD "$layer" -C "$LAYER_DIR" \
        --exclude="./dev/*" \
        --exclude="dev/*" \
        --no-same-owner \
        2>/dev/null || true

      mkdir -p "$LAYER_DIR/dev"
      $REPACK_CMD "$layer" -C "$LAYER_DIR" .
      rm -rf "$LAYER_DIR"

      # NEW compressed hash for manifest.json filename
      local NEW_HASH=$(sha256sum "$layer" | cut -d' ' -f1)
      local NEW_FILENAME="${NEW_HASH}.tar.gz"

      # NEW DiffID after repacking — IS_GZIP used here
      if [ "$IS_GZIP" = true ]; then
        local NEW_DIFFID=$(gunzip -c "$layer" | sha256sum | cut -d' ' -f1)
      else
        local NEW_DIFFID=$(sha256sum < "$layer" | cut -d' ' -f1)
      fi

      echo "   Compressed: ${OLD_HASH:0:12}... -> ${NEW_HASH:0:12}..."
      echo "   DiffID:     ${OLD_DIFFID:0:12}... -> ${NEW_DIFFID:0:12}..."

      # Rename layer file to new hash
      mv "$layer" "$(dirname $layer)/$NEW_FILENAME"

      # Update manifest.json layer filename reference
      sed -i "s|${OLD_FILENAME}|${NEW_FILENAME}|g" "$WORKDIR/manifest.json"

      # Update config DiffID by replacing old with new
      if [ -f "$CONFIG_PATH" ]; then
        sed -i "s|sha256:${OLD_DIFFID}|sha256:${NEW_DIFFID}|g" "$CONFIG_PATH"
        echo "   Config updated: $CONFIG_FILE"
      else
        echo "  WARNING: Config file not found: $CONFIG_FILE"
      fi

    else
      echo " No /dev/console entries in $(basename $layer), skipping"
    fi

  done

  if [[ "$filtered" == true ]]; then
      echo "repacking filtered image..."
      sed -i "s/^/layerfiltered/" "$img_local_tar_path.image_digest"
      tar -cf "$CLEAN_TAR" -C "$WORKDIR" . \
        && rm $img_local_tar_path \
        && mv $CLEAN_TAR $img_local_tar_path \
        && echo "Image sucessfully filtered and replaced." \
        || { echo "image filtering/packing failed"; exit 1; }
      echo
  else
      echo "no /dev/console layers found."
  fi
  rm -rf "$WORKDIR"
  echo "Finished filtering layers."
}

# setup paths for working with image
img_local_path=$docker_img_dir/$(echo "$docker_pull_image" | tr : -)
mkdir -p $img_local_path
img_local_tar_path="$img_local_path.tar"

# check for crane, download if needed, so we can retrieve image without hitting /dev/console errors in LinuxServer images, and getting digest without downloading remote image (and will works on all public registries)
if [[ ! -f "$docker_bin/crane" ]]; then
    curl -sL "$CRANE_TAR_URL" | tar xz -C "$docker_bin" crane && echo "downloaded missing crane binary" || echo "failed to obtain crane binary, this will cause issues !"
fi

# check for presence of registry auth login
echo "checking for docker auth against pull image, $docker_pull_image"
if [[ -f "$img_local_tar_path.auth" ]]; then
    if [[ "$( cat $img_local_tar_path.auth )" == "true" ]]; then
        echo "image requires authenticating"
        rollback "IMAGE_AUTH_NEEDED"
    else
        mv "$img_local_tar_path.auth" "$user_dir/.docker/config.json"
        echo "true" > "$img_local_tar_path.auth"
        echo "docker auth found and moved into place for repo \"${docker_pull_image%%/*}\""
    fi
else
    echo "no auth found or needed."
    echo "{}" > "$user_dir/.docker/config.json"
fi

# Check if the image exists locally, and if it matches remote registry, will use $docker_pull_image for image name, due to custom settings filter.
if [[ ! -d "$img_local_path" ]] || [[ ! -f "${img_local_tar_path}.image_digest" ]]; then

    echo "Image $docker_pull_image, or image digest hash not found locally..."
    if [[ "$BLOCK_ALL_PULL" == "true" ]] || [[ "$docker_image" == "$REPUTATION_IMAGE" && "$BLOCK_REP_PULL" == "true" ]]; then echo "Image pull has been blocked by host settings" && rollback "IMAGE_PULL_BLOCKED"; fi
    #"$docker_bin"/download-frozen-image-v2.sh $img_local_path $docker_pull_image || rollback "DOCKER_PULL"
    #DOCKER_HOST="$dockerd_socket" timeout --foreground -v -s SIGINT "$docker_pull_timeout_secs" "$docker_bin"/docker pull $docker_pull_image || rollback "DOCKER_PULL"

    #IMAGE_DIGEST=$(DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker image inspect --format='{{index .RepoDigests 0}}' $docker_pull_image | cut -d'@' -f2)
    #TOKEN=$(curl -s "${DOCKER_AUTH_URL}$(echo "$docker_pull_image" | cut -d':' -f1):pull" | jq -r '.token') \
    #&& IMAGE_DIGEST=$(curl -s --head -H "Authorization: Bearer $TOKEN" ${DOCKER_REGISTRY_URL}$(echo "$docker_pull_image" | cut -d':' -f1)/manifests/${docker_image_version} | sed -n 's/.*[Dd]ocker-[Cc]ontent-[Dd]igest: \(sha256:[a-f0-9]*\).*/\1/p')

    echo "querying image size and digest hash..."
    if IMAGE_MANIFEST=$(DOCKER_CONFIG="$user_dir/.docker" "$docker_bin/crane" manifest --platform linux/amd64 $docker_pull_image ) \
      && IMAGE_DIGEST=$(echo -n "$IMAGE_MANIFEST" | sha256sum | awk '{print "@sha256:" $1}' > "${img_local_tar_path}.image_digest") \
      && IMAGE_SIZE=$(echo "$IMAGE_MANIFEST" | jq -c '[.config.size] + [.layers[].size] | add'); then
        if [[ "$(bc <<< "scale=0; $IMAGE_SIZE / 1024")" -lt "$disk" ]]; then
            echo "pulling image ( with size of $(bc <<< "scale=2; $IMAGE_SIZE / 1073741824")GB  )..."
            DOCKER_CONFIG="$user_dir/.docker" "$docker_bin/crane" pull --platform linux/amd64 $docker_pull_image $img_local_tar_path || { echo "Failed to pull ${docker_pull_image:-"unknown image"}, aborting"; rollback "DOCKER_PULL"; }
        else
            echo "requested docker image of $(bc <<< "scale=2; $IMAGE_SIZE / 1073741824")GB is over the size of allowed instance $(bc <<< "scale=2; $disk / 1024 / 1024")GB, exiting."
            rollback "DOCKER_SIZE"
        fi
    else
        echo "Failed to get image manifest/digest/size, does $docker_pull_image exist on remote registry? or need authenticating"
        rollback "DOCKER_MANIFEST"
    fi

    echo "checking image for /dev/console layers..."
    image_layer_filter $img_local_tar_path || rollback "DOCKER_STRIP_DEV"

    #echo "Saving the downloaded image as a tarball: $img_local_tar_path"
    #tar -cvf $img_local_tar_path -C $img_local_path . || rollback "DOCKER_PULL"
    #DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker save -o "$img_local_tar_path" $docker_pull_image || rollback "DOCKER_SAVE_TAR"
    echo "docker image filtered, saved as a tarball, along with its image digest, now loading it into docker..."
    DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker load -i "$img_local_tar_path" || rollback "DOCKER_LOAD"

elif [[ "$BLOCK_ALL_PULL" == "true" ]] || [[ "$docker_image" == "$REPUTATION_IMAGE" && "$BLOCK_REP_PULL" == "true" ]]; then
    echo "**** Image pull has been blocked by host settings   ****"
    echo "Loading existing docker image $img_local_tar_path."
    DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker load -i "$img_local_tar_path" || rollback "DOCKER_LOAD"
    echo "Docker image $img_local_tar_path load complete."

else

    echo "Image $docker_pull_image, already exists locally, checking if remote hash matches..."

    # If first segment of image has a dot or colon, it's an external registry
    docker_pull_image_first_segment="${docker_pull_image%%/*}"
    if [[ "$docker_pull_image_first_segment" == *"."* ]] || [[ "$docker_pull_image_first_segment" == *":"* ]]; then
        echo "image detected as from a external registry..."
        IMAGE_DIGEST=$(DOCKER_CONFIG="$user_dir/.docker" "$docker_bin/crane" digest --platform linux/amd64 "$docker_pull_image") \
          && RATE_LIMIT_REMAINING=100 \
          || { echo "fault occured getting manifest, ratelimited?, no acccess/permisson?"; RATE_LIMIT_REMAINING=0; }
    else
        TOKEN=$(curl -s "${DOCKER_AUTH_URL}$(echo "$docker_pull_image" | cut -d':' -f1):pull" | jq -r '.token' || echo "" ) \
            && IMAGE_DIGEST=$(curl -s --head -H "Authorization: Bearer $TOKEN" ${DOCKER_REGISTRY_URL}$(echo "$docker_pull_image" | cut -d':' -f1)/manifests/${docker_image_version} | sed -n 's/.*[Dd]ocker-[Cc]ontent-[Dd]igest: \(sha256:[a-f0-9]*\).*/\1/p' || echo "" ) \
            && RATE_LIMIT_REMAINING=$(curl -s --head -s -H "Authorization: Bearer $TOKEN" ${DOCKER_REGISTRY_URL}ratelimitpreview/test/manifests/latest | sed -n 's/.*[Rr]atelimit-remaining: \([0-9]*\).*/\1/p' | tr -d '\r' | tail -1 || echo 0 ) \
            || { echo "fault occured getting token, image digest, or rate limit infomation"; RATE_LIMIT_REMAINING=0; }
    fi

    # Check if re-pull is needed, and we have a good amount of "remaining" rate pulls left
    if [[ "$IMAGE_DIGEST" != "$(cat "${img_local_tar_path}.image_digest" 2>/dev/null | cut -d'@' -f2)" ]]; then
            echo "\"$(cat "${img_local_tar_path}.image_digest" 2>/dev/null | cut -d'@' -f2 || true)\" local image hash not equal to,"
            echo "\"$IMAGE_DIGEST\" remote registry image,"
        if [[ ${RATE_LIMIT_REMAINING:-0} =~ ^[0-9]+$ ]] && [[ ${RATE_LIMIT_REMAINING:-0} -gt 40 ]]; then
            echo "rate limit is above 60 ( current rate limit = ${RATE_LIMIT_REMAINING:-0} ),"
            echo "re-pulling image..."
            #DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker pull $docker_pull_image || rollback "DOCKER_PULL"
            #DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker save -o "$img_local_tar_path" $docker_pull_image || rollback "DOCKER_PULL"
            DOCKER_CONFIG="$user_dir/.docker" "$docker_bin/crane" pull --platform linux/amd64 $docker_pull_image $img_local_tar_path || rollback "DOCKER_PULL"
            echo "@$IMAGE_DIGEST" > "${img_local_tar_path}.image_digest"
            echo "checking image for /dev/console layers..."
            image_layer_filter $img_local_tar_path || rollback "DOCKER_LAYER_FILTER"
            echo
            echo "docker image pulled, saved tarball at $img_local_tar_path, refreshed image digest, now loading into docker..."
            DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker load -i "$img_local_tar_path" || rollback "DOCKER_LOAD"
        else
            echo "we are rate limited (remaining = ${RATE_LIMIT_REMAINING:-0}), so not able to pull new image,"
            echo "will continue to use exsisting image ( $img_local_tar_path ) until rate limit improves, now loading into docker..."
            DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker load -i "$img_local_tar_path" || rollback "DOCKER_LOAD"
        fi
    else
        echo "File hash matches remote registry,"
        echo "local hash  = $(cat ${img_local_tar_path}.image_digest 2>/dev/null | cut -d'@' -f2)"
        echo "remote hash = ${IMAGE_DIGEST}"
        echo
        echo "Loading docker image $img_local_tar_path."
        DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker load -i "$img_local_tar_path" || rollback "DOCKER_LOAD"
        echo "Docker image $img_local_tar_path load complete."
    fi
fi

# now we have the image pulled, we null any auth info reducung exposure.
# have a setting for savng/notsaving auth info. this would be where we null it. currently it does get wipped on instance end (as its in user area)
# echo "{}" > "$user_dir/.docker/config.json"

echo "making sure pulled image has all tags needed to work (on the original bootup needing full image for sashimono, and if its been filtered)"
DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker tag ${docker_pull_image} ${docker_image} || rollback "DOCKER_TAG"
DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker tag ${docker_pull_image} $(registry_filter $docker_pull_image) || rollback "DOCKER_TAG2"
echo "$( cat ${img_local_tar_path}.image_digest 2>/dev/null )" > "$user_dir"/.docker/image_digest
if [[ "$( cat ${img_local_tar_path}.image_digest 2>/dev/null )" == "layerfiltered"* ]]; then
    docker_pull_image=$(registry_filter $docker_pull_image)
    echo "Docker tag update complete, alterd registry prefix as image filtered, altered pull image $docker_pull_image full image $docker_image"
else
    echo "Docker tag update complete, original pulled image $docker_pull_image  full image $docker_image"
fi


echo
echo "Adding hpfs mounts, and depending on instance options, docker_recreate or docker_vars services."

echo "[Unit]
Description=Running and monitoring contract fs.
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=/bin/bash -c '( ! /bin/grep -qs $user_dir/$contract_dir/contract_fs/mnt /proc/mounts ) || /bin/fusermount -u $user_dir/$contract_dir/contract_fs/mnt'
EnvironmentFile=-$user_dir/.serviceconf
ExecStart=/bin/bash -c '$script_dir/hpfs fs -f $user_dir/$contract_dir/contract_fs -m $user_dir/$contract_dir/contract_fs/mnt -u $contract_host_uid:$contract_host_gid -t \${HPFS_TRACE}\$([ \$HPFS_MERGE = \"true\" ] && echo \" -g\")'
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target" >"$user_dir"/.config/systemd/user/contract_fs.service

echo "[Unit]
Description=Running and monitoring ledger fs.
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=/bin/bash -c '( ! /bin/grep -qs $user_dir/$contract_dir/ledger_fs/mnt /proc/mounts ) || /bin/fusermount -u $user_dir/$contract_dir/ledger_fs/mnt'
EnvironmentFile=-$user_dir/.serviceconf
ExecStart=$script_dir/hpfs fs -f $user_dir/$contract_dir/ledger_fs -m $user_dir/$contract_dir/ledger_fs/mnt -t \${HPFS_TRACE} -g
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target" >"$user_dir"/.config/systemd/user/ledger_fs.service


## setup NPM+ if host has NPMplus installed
if [[ "$TLS_TYPE" == "NPMplus" ]]; then
    echo "NPMplus install detected"

    if [[ -n "$custom_docker_domain" ]]; then
        if [[ ! -f "/usr/bin/sashimono/acme.sh" ]]; then
            echo "base acme.sh missing, re-installing"
            wget -O /usr/bin/sashimono/acme.sh "$ACME_SH_URL"
            chmod +x /usr/bin/sashimono/acme.sh
        fi
        if [[ ! -f "/usr/bin/sashimono/dns_evernode.sh" ]]; then
            echo "base evernode dns plugin for acme.sh missing, re-installing"
            wget -O /usr/bin/sashimono/dns_evernode.sh "$ACME_DNS_PLUGIN_URL"
            chmod +x /usr/bin/sashimono/dns_evernode.sh

            mkdir -p /root/.acme.sh
            cp /usr/bin/sashimono/dns_evernode.sh /root/.acme.sh/dns_evernode.sh
        fi

        mkdir -p $user_dir/.acme.sh/
        cp /usr/bin/sashimono/acme.sh $user_dir/.acme.sh/acme.sh
        cp /usr/bin/sashimono/dns_evernode.sh $user_dir/.acme.sh/dns_evernode.sh
        chown -R $user:$user $user_dir/.acme.sh/
    fi


cat > "$user_dir"/.docker/domain_ssl_update.sh <<EOF 
#!/bin/bash
# setup/update domain SSL and proxy host...
version=$version
echo "##########################################################" && echo "#" && echo "## script running version: \$version at date: \$(date)" && echo
user=$user
user_dir=$user_dir
contract_dir=$contract_dir
MBXRPL_CONFIG="$MBXRPL_CONFIG"
NAMESERVER_OVERRIDE=$NAMESERVER_OVERRIDE
NPM_URL="$(jq -r ".proxy.npm_url | select( . != null )" "$MBXRPL_CONFIG")"
NPM_TOKEN="$(jq -r ".npm.token | select( . != null )" "$(jq -r ".proxy.npm_tokenPath | select( . != null )" "$MBXRPL_CONFIG")")"
instance_publickey=\$(cat "$user_dir/.docker/instance_publickey" 2>/dev/null || { true; echo ""; } )
custom_docker_domain_ssl="$custom_docker_domain_ssl"
custom_docker_domain_dns="$custom_docker_domain_dns"
custom_docker_domain_scheme="$custom_docker_domain_scheme"
custom_docker_domain="$custom_docker_domain"
custom_docker_subdomain="$custom_docker_subdomain"
internal_block_exploits=${internal_block_exploits:-1}
tls_type="$TLS_TYPE"
instance_slot=${user_port: -1}
web_port="$gp_tcp_port_start"
EVERNODE_HOSTNAME="$EVERNODE_HOSTNAME"
SSL_PRIVATE_KEY="$user_dir/.docker/.ssl_private.key"

# 1st check for blacklisted domain, and null if present.
if [[ -n "\$custom_docker_domain" ]]; then
    blacklist_domains=\$(jq -r ".proxy.blacklist[] | select( . != null )" "\$MBXRPL_CONFIG")
    for blacklist_domain_check in \$blacklist_domains; do
        if [[ "\$custom_docker_domain" == *"\$blacklist_domain_check"* ]]; then
            echo "blacklisted domain used in domain request :\$blacklist_domain_check NOT adding domain!."
            tls_type="failed"
            break
        fi
    done
fi

# 2nd check if domain has authorization to be used in this instance.
if [[ -n "\$custom_docker_domain" ]]; then
    domain_txtrecord=\$(dig +short +time=10 +tries=3 TXT "\$custom_docker_domain" @\$NAMESERVER_OVERRIDE)
    if [[ \${#instance_publickey} -gt 10 ]] && [[ \${#domain_txtrecord} -gt 10 ]] && echo "\$domain_txtrecord" | grep -q "\$instance_publickey"; then
        echo "contract pubic key, '\$instance_publickey'."
        echo "domain \$custom_docker_domain authorized, as contract public key present in the TXT records."
    else
        echo "contract pubic key, '\$instance_publickey'."
        echo "domain resolved TXT records, \$domain_txtrecord"
        echo "domain \$custom_docker_domain NOT authorized as key NOT found in the TXT records."
        echo "not adding domain !"
        tls_type="failed"
    fi
else
    echo "no domain authorization check needed, as no domain requested."
fi

# setup domain on NPM+ (if requested. passed checks above, and host has NPMplus installed)
if [[ "\$tls_type" == "NPMplus" ]]; then
  echo "domain initial setup checks passed, continuing..."
  echo

  NPM_CERT_ID=""
  NPM_CERT_ID_WILD="false"
  NPM_CERT_UPDATE="false"

  if [[ -z "\$NPM_URL" || -z "\$NPM_TOKEN" ]]; then
    echo "NPMplus  URL, or Token not set...  url=\"\$NPM_URL\" token=\"\$NPM_TOKEN\""
  else
    NPM_CHECK_EMAIL_RESPONSE=\$(curl -k -s -m 10 -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/users/me | jq -r '.email // "no user response"' || echo "no json output" )
    if ! [[ \$NPM_CHECK_EMAIL_RESPONSE =~ .+@.+ ]]; then
         echo "NPMplus URL incorrect...  url=\"\$NPM_URL\" url_response=\"\$NPM_CHECK_EMAIL_RESPONSE\""
    else
        if [[ -n "\$custom_docker_subdomain" ]]; then
            custom_docker_domain="\$custom_docker_subdomain.\${EVERNODE_HOSTNAME#*.}"
            echo "subdomain request detected, assigning domain as \$custom_docker_domain"
        fi
        if [[ -z "\$custom_docker_domain" ]]; then
            custom_docker_domain="\${EVERNODE_HOSTNAME%%.*}-\${instance_slot}.\${EVERNODE_HOSTNAME#*.}"
            custom_docker_subdomain="\${custom_docker_domain%%.*}"
            echo "no custom domain settings found, setting up a default route of, \$custom_docker_domain"
        fi

        # do we need SSL files ?
        if [[ "\$custom_docker_domain_ssl" == "true" ]]; then
            echo "checking local domain TLS files... "
            # FIRST check NPM+
            NPM_CERT_EMAIL=\$(jq -r ".host.emailAddress | select( . != null )" "\$MBXRPL_CONFIG")
            NPM_CERT_LIST=\$(curl -k -s -m 100 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates || echo "" )
            NPM_CERT_JSON=\$(echo "\$NPM_CERT_LIST" | jq -r --arg d "\$custom_docker_domain" ' [ .[] | select(any(.domain_names[]?; . == \$d)) ] | if length == 0 then "" else (sort_by(.expires_on) | last | .) end' || echo "" )

            # check for wildcard domain too (mainly needed for subdomain/defaulted domain)
            if [[ -z "\$NPM_CERT_JSON" ]]; then
                NPM_CERT_JSON=\$(echo "\$NPM_CERT_LIST" | jq -r --arg d "*.\${custom_docker_domain#*.}" ' [ .[] | select(any(.domain_names[]?; . == \$d)) ] | if length == 0 then "" else (sort_by(.expires_on) | last | .) end' || echo "" )
                if [ -n "\$NPM_CERT_JSON" ]; then 
                    NPM_CERT_ID_WILD="true"
                fi
            fi

            # get extra provider data and expiry if we now have ID
            if [[ -n "\$NPM_CERT_JSON" ]]; then 
                NPM_CERT_ID=\$(echo "\$NPM_CERT_JSON" | jq -r '.id')
                NPM_CERT_PROVIDER=\$(echo "\$NPM_CERT_JSON" | jq -r '.provider // empty')
                if [ "\$NPM_CERT_PROVIDER" == "other" ]; then
                    NPM_CERT_META=\$(echo "\$NPM_CERT_JSON" | jq -r '.meta // empty')
                    NPM_CERT_META_CERT=\$(echo "\$NPM_CERT_META" | jq -r '.certificate // empty')
                    NPM_CERT_META_KEY=\$(echo "\$NPM_CERT_META" | jq -r '.certificate_key // empty')
                fi

                NPM_CERT_EXPIRE=\$(echo "\$NPM_CERT_JSON" | jq -r '.expires_on // empty')
                NPM_CERT_EXPIRE_epoch=\$(date -d "\$NPM_CERT_EXPIRE" +%s)
                inthree_days_epoch=\$(date -d "\$(date -d "+3 days" +%Y-%m-%d)" +%s)
                if [ "\$NPM_CERT_EXPIRE_epoch" -lt "\$inthree_days_epoch" ]; then
                    echo "TLS files need updating, Expiry=\$NPM_CERT_EXPIRE"
                    NPM_CERT_UPDATE="true"
                fi
            fi
            ##echo "ID check point NPM_CERT_ID:>\${NPM_CERT_ID}<"

            if [[ -z \${NPM_CERT_ID//[[:space:]]/} || "\$NPM_CERT_UPDATE" == "true" ]]; then
                echo "files for domain \$custom_docker_domain, not found locally or need updating. "
                echo "(INFO: updatingStatus=\${NPM_CERT_UPDATE} provider=\${NPM_CERT_PROVIDER} expiry=\${NPM_CERT_EXPIRE} ) "
                echo

                # SECOND search on other authorized evernodes.
                if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" || "\$NPM_CERT_UPDATE" == "true" ]] && [[ -z "\$custom_docker_subdomain" ]]; then
                    while true; do
                        echo "checking other authorized evernodes for SSL files."
                        nameserver_override="@\$NAMESERVER_OVERRIDE"
                        full_domain="_acme-challenge.\$custom_docker_domain"
                        ENCRYPTED_FILE="\$user_dir/\$contract_dir/tls/encrypted_tls_files.zip"
                        DECRYPTED_TLS_ZIP="\$user_dir/\$contract_dir/tls/tls-files.zip"
                        if [[ "\$SSL_PRIVATE_KEY" == "null" ]] || [[ -z "\$SSL_PRIVATE_KEY" ]]; then
                            echo "Error: unable to confirm we have Private key for SSL decryption, contact evernode Admin"
                            break
                        else 
                                if ! openssl pkey -in "\$SSL_PRIVATE_KEY" -check -noout >/dev/null 2>&1; then
                                    echo "Error: Invalid private key for the SSL decryption, contact evernode Admin"
                                    break
                                fi
                        fi

                        # Step 1: Fetch authoritative nameservers for the authoritative domain.
                        # make sure we have zone/parent-domain correct
                        zone_parent_domain=\$(dig +noall +answer +authority SOA "\$custom_docker_domain" \$nameserver_override 2>/dev/null | awk '\$4 == "SOA" {print \$1}' | sed 's/\.$//' | head -n1)

                        if [ -z "\$zone_parent_domain" ]; then
                            echo "Unable to determine the authoritative zone via SOA method, trying via trace..."
                            dots=\$(echo "\$custom_docker_domain" | tr -cd '.' | wc -c)
                            if [ "\$dots" -gt 1 ]; then
                                zone_parent_domain=\$(dig +trace +time=1 +tries=1 "\$custom_docker_domain" \$nameserver_override | 
                                    grep -v "^;" | 
                                    sed -n 's/^\([^[:space:]]\+\)[[:space:]]\+[0-9]\+[[:space:]]\+IN[[:space:]]\+NS[[:space:]].*/\1/p' | 
                                    tail -n1)
                            else
                                zone_parent_domain="\$custom_docker_domain"
                            fi
                        fi

                        if [ -z "\$zone_parent_domain" ]; then
                            echo "Unable to determine the authoritative zone for \$full_domain via \$nameserver_override (maybe domain has not fully propegated to this DNS server)"
                            echo; break
                        else
                            echo "Authoritative zone for \$full_domain is \$zone_parent_domain."

                            # now we 100% have zone, we can get all nameservers of root domain, ready for next step
                            ns_parent_domain=\$(dig +short NS "\$zone_parent_domain" "\$nameserver_override")
                            if [ -z "\$ns_parent_domain" ]; then
                                echo "NO authoritative nameservers found for \$custom_docker_domain, unable to continue checking other Evernodes."
                                echo
                            else
                                echo "nameserver list secured, with \$(echo "\$ns_parent_domain" | wc -l) in list."
                                echo -e "\$ns_parent_domain"
                                echo

                                # Step 2: Iterate through the nameservers of the root domain. 
                                for ns in \$ns_parent_domain; do
                                    echo "Querying \$ns for NS records of \$full_domain..."
                                    echo

                                    # Step 3: get full list of "NS records" held for _acme-challenge subdomain for domain we want SSL for.
                                    ns_challenge_domain=\$(dig +norecurse +noall +authority NS "\$full_domain" @"\$ns")

                                    # process the above NS records, store in new variable, so we can check validity (using sed to comply with acme.sh hook plugin environment)
                                    ns_records=\$(echo "\$ns_challenge_domain" | sed -n '/IN[[:space:]]\+NS/{s/.*[[:space:]]\([^[:space:]]\+\)$/\1/;p}')

                                    # Check if processed response is empty, if so, try next name server.
                                    if [ -z "\$ns_records" ]; then
                                        echo "error in response from \$ns. Trying next nameserver..."
                                        echo "processed response \$ns_records:\n\$ns_records"
                                        echo "actual dig response from \$ns:\n\$ns_challenge_domain"
                                        echo
                                        continue
                                    else
                                        echo -e "good response from \$ns, with a list of \$(echo "\$ns_records" | wc -l) NS records to check..."
                                        echo -e "\$ns_records"
                                        echo
                                    fi

                                    # Step 4: iterate through each NS record from the pre-prepared variable in Step 3
                                    for ns_record in \$ns_records; do
                                        echo "Processing NS record: \$ns_record."
                                        if [[ "\$ns_record" == "\$EVERNODE_HOSTNAME"* ]]; then
                                            echo "skipping \$ns_record, as that is this evernode."
                                            echo
                                            continue
                                        fi

                                        # Step 5: send API request for SSL files
                                        mkdir -p \$user_dir/\$contract_dir/tls
                                        API_RESPONSE=\$(curl -s -m 200 -w "\n%{http_code}" -X POST -H "Content-Type: application/json; charset=UTF-8" -d '{ "type":"ssl_request","domain":"'"\$custom_docker_domain"'","keyDomain":"'"\$EVERNODE_HOSTNAME"'" }' --output \$ENCRYPTED_FILE https://\$ns_record/api-ssl)
                                        API_STATUS=\$(echo "\$API_RESPONSE" | tail -n1)
                                        ## echo "API response statuss=\${API_STATUS}<"
                                        if [[ "\$API_STATUS" == "200" ]]; then
                                            if [[ -f "\$ENCRYPTED_FILE" ]]; then
                                                echo "encrypted tls files obtained, now decrypting..."

                                                # Read key length (first 4 bytes, big-endian) and convert to decimal
                                                KEY_LEN=\$(dd if="\$ENCRYPTED_FILE" bs=1 count=4 status=none 2>/dev/null | od -An -tu4 --endian=big | tr -d ' ')
                                                if [[ -z "\$KEY_LEN" ]] || [[ "\$KEY_LEN" -lt 1 ]]; then
                                                    echo "Error: Failed to read encrypted key length = \$KEY_LEN bytes"
                                                    continue
                                                fi

                                                # Calculate offsets
                                                OFFSET_KEY=4
                                                OFFSET_IV=\$((4 + KEY_LEN))
                                                OFFSET_ZIP=\$((4 + KEY_LEN + 16))

                                                # Extract and decrypt AES key directly to hex var
                                                echo "Decrypting AES key with RSA using this evenodes private key..."
                                                AES_KEY_HEX=\$(dd if="\$ENCRYPTED_FILE" bs=1 skip=\$OFFSET_KEY count=\$KEY_LEN status=none 2>/dev/null | \\
                                                    openssl pkeyutl -decrypt \\
                                                        -inkey "\$SSL_PRIVATE_KEY" \\
                                                        -pkeyopt rsa_padding_mode:oaep \\
                                                        -pkeyopt rsa_oaep_md:sha256 2>/dev/null | \\
                                                    xxd -p -c 256 | tr -d '\n')
                                                if [[ \${#AES_KEY_HEX} -ne 64 ]]; then  # 32 bytes -> 64 hex chars
                                                    echo "Error: Failed to decrypt AES key (invalid length: \${#AES_KEY_HEX} chars, expected 64)"
                                                    continue
                                                fi

                                                # Extract IV to hex var (16 bytes for CBC)
                                                echo "Extracting IV..."
                                                IV_HEX=\$(dd if="\$ENCRYPTED_FILE" bs=1 skip=\$OFFSET_IV count=16 status=none 2>/dev/null | xxd -p -c 256 | tr -d '\n')
                                                if [[ \${#IV_HEX} -ne 32 ]]; then  # 16 bytes -> 32 hex chars
                                                    echo "Error: Invalid IV length: \${#IV_HEX} chars, expected 32"
                                                    continue
                                                fi

                                                # Decrypt zip: pipe encrypted data directly to openssl
                                                echo "Decrypting zip with AES_KEY using AES-256-CBC..."
                                                if ! dd if="\$ENCRYPTED_FILE" bs=1 skip=\$OFFSET_ZIP status=none 2>/dev/null | \\
                                                    openssl enc -d -aes-256-cbc \\
                                                        -K "\$AES_KEY_HEX" \\
                                                        -iv "\$IV_HEX" \\
                                                        -out "\$DECRYPTED_TLS_ZIP" 2>/dev/null; then
                                                    echo "Error: Failed to decrypt zip with AES-CBC"
                                                    continue
                                                fi

                                                echo "✓ Decryption successful! zipped size: \$(wc -c < "\$DECRYPTED_TLS_ZIP") bytes"
                                                echo "now unzipping..."

                                                unzip -o \$DECRYPTED_TLS_ZIP -d \$user_dir/\$contract_dir/tls &&
                                                chown -R \$user:\$user \$user_dir/\$contract_dir/tls &&
                                                if [ "\$NPM_CERT_UPDATE" == "false" ]; then
                                                NPM_CERT_ADD=\$(curl -k -sS -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -d '{"provider":"other","nice_name":"'"\$custom_docker_domain"'"}' \$NPM_URL/api/nginx/certificates ) &&
                                                NPM_CERT_ID=\$(jq -r '.id' <<< "\$NPM_CERT_ADD") &&
                                                echo "obtained new certificate, for domain \$custom_docker_domain, ID is \$NPM_CERT_ID, now uploading to NPM+..." 
                                                else echo "obtained new certificate, for domain \$custom_docker_domain, updating existing NPM+ ID \$NPM_CERT_ID, now uploading to NPM+ for future..."
                                                fi &&
                                                NPM_CERT_UPLOAD=\$(curl -k -sS -m 100 -X POST "\$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID/upload" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -F "certificate=@\$user_dir/\$contract_dir/tls/cert.pem" -F "certificate_key=@\$user_dir/\$contract_dir/tls/privkey.pem") &&
                                                NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1" &&
                                                NPM_CERT_UPDATE="false" &&
                                                echo "sleeping for 5 seconds to allow NPM+ processing time" && sleep 5 && break 4 \\
                                                    || { \\
                                                        echo "failed to fetch, add certificate ID, or upload file to local NPM, this WILL cause issues. ERROR; debug_ADD:\$NPM_CERT_ADD  debug_ID:\$NPM_CERT_ID  debug_UPLOAD:\$NPM_CERT_UPLOAD"; \\
                                                        echo "flushing any entries from NPMplus for domain \$custom_docker_domain..."; \\
                                                        curl -k -sS -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID; \\
                                                        NPM_CERT_ID="";
                                                        }
                                            else
                                                echo "error occured: no response from API call"
                                            fi
                                        else
                                            echo "error occured calling \$ns_record, API response status was :\$API_STATUS"
                                            echo "message of :\$( cat \$ENCRYPTED_FILE)"
                                            echo
                                        fi
                                        echo
                                    done
                                    break
                                done
                            fi
                        fi
                        break
                    done
                fi
            
                # THIRD try obtain them via a DNS-01 method.
                if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" || "\$NPM_CERT_UPDATE" == "true" ]] && [[ -z "\$custom_docker_subdomain" ]] && [[ "\$custom_docker_domain_dns" == "dns" ]]; then 
                    echo "not found on other authorized evernodes, will use acme.sh DNS-01 challenge and evernodes DNS API to obtain SSL files..." 
                    mkdir -p \$user_dir/\$contract_dir/tls
                    \$user_dir/.acme.sh/acme.sh --issue \\
                        --server letsencrypt \\
                        --dns dns_evernode \\
                        --domain "\$custom_docker_domain" --force \\
                        --accountemail "\$NPM_CERT_EMAIL" \\
                        --nocron \\
                        --noprofile \\
                        --useragent  "evernode-domain-system" \\
                        --cert-file \$user_dir/\$contract_dir/tls/cert.pem \\
                        --key-file \$user_dir/\$contract_dir/tls/privkey.pem \\
                        --ca-file \$user_dir/\$contract_dir/tls/chain.pem \\
                        --fullchain-file \$user_dir/\$contract_dir/tls/fullchain.pem \\
                        && chown -R \$user:\$user \$user_dir/\$contract_dir/tls \\
                        && if [ "\$NPM_CERT_UPDATE" == "false" ]; then
                            NPM_CERT_ADD=\$(curl -k -sS -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -d '{"provider":"other","nice_name":"'"\$custom_docker_domain"'"}' \$NPM_URL/api/nginx/certificates ) \\
                            && NPM_CERT_ID=\$(jq -r '.id' <<< "\$NPM_CERT_ADD") \\
                            && echo "created new certificate, and entry for host domain \$custom_docker_domain, ID is \$NPM_CERT_ID, now uploading to NPM+..."
                        else echo "created new certificate, for host domain \$custom_docker_domain, updating existing NPM+ ID \$NPM_CERT_ID, now uploading..."; fi \\
                        && NPM_CERT_UPLOAD=\$(curl -k -sS -m 100 -X POST "\$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID/upload" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -F "certificate=@\$user_dir/\$contract_dir/tls/fullchain.pem" -F "certificate_key=@\$user_dir/\$contract_dir/tls/privkey.pem") \\
                        && NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1" \\
                        && NPM_CERT_UPDATE="false" \\
                            || { \\
                                echo "failed to create, add certificate ID, or upload file, this WILL cause issues. ERROR; debug_ADD:\$NPM_CERT_ADD  debug_ID:\$NPM_CERT_ID  debug_UPLOAD:\$NPM_CERT_UPLOAD"; \\
                                echo "flushing any entries from NPMplus for domain \$custom_docker_domain..."; \\
                                curl -k -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID; \\
                                NPM_CERT_ID="";
                                }
                fi


                # FOURTH if neither DNS-1 or if its not found on other authorized evernodes, fallback to the weak http-01 method.
                if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" || "\$NPM_CERT_UPDATE" == "true" ]] && [[ -z "\$custom_docker_subdomain" ]] && [[ "\$custom_docker_domain_dns" == "dns" ]]; then
                    if [ -z "\$custom_docker_subdomain" ]; then echo "certificate creation via DNS-01 method failed, and wasn't found on other authorized evernodes."; fi
                    echo
                    echo "trying via NPM+ with a more standard HTTP-01 method..."
                    NPM_CERT_ADD=\$(curl -k -s -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -d '{"provider":"letsencrypt","nice_name":"'"\$custom_docker_domain"'"}' \$NPM_URL/api/nginx/certificates ) || echo "failed to create certificate for this evernode, this WILL cause issues. ERROR; debug: \$NPM_CERT_ADD"
                    NPM_CERT_ID=\$(jq -r '.id' <<< "\$NPM_CERT_ADD") && echo "created new certificate for host domain \$custom_docker_domain, ID is \$NPM_CERT_ID" || echo "failed to find certificate ID, this WILL cause issues. ERROR; debug1: \$NPM_CERT_ADD debug2: \$NPM_CERT_ID"
                    if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" ]]; then
                        echo "certificate add failed via http-01 method, setting up domain with no SSL. debug_ADD:\$NPM_CERT_ADD   debug_ID:\$NPM_CERT_ID"
                        echo "flushing any broken ssl entries in NPMplus for domain \$custom_docker_domain"
                        NPM_CERT_LIST=\$(curl -k -s -m 100 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates || echo "" )
                        NPM_CERT_ID=\$(echo "\$NPM_CERT_LIST" | jq -r --arg d "\$custom_docker_domain" ' [ .[] | select(any(.domain_names[]?; . == \$d)) ] | if length == 0 then "" else (sort_by(.expires_on) | last | .id) end' || echo "" )
                        NPM_CERT_DELETE=\$(curl -k -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID)
                        echo "flushed? debug_ID:\$NPM_CERT_ID debug_DELETE:\$NPM_CERT_DELETE"
                        NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                    else
                        echo "certificate added, for host domain \$custom_docker_domain, with ID:\$NPM_CERT_ID  WILDCARD:\$NPM_CERT_ID_WILD"
                        mkdir -p \$user_dir/\$contract_dir/tls
                        if { 
                            curl -k --output \$user_dir/\$contract_dir/tls/tls_files.zip -m 10 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID/download &&
                            unzip \$user_dir/\$contract_dir/tls/tls_files.zip -d \$user_dir/\$contract_dir/tls &&
                            echo "downloaded certificate ID \$NPM_CERT_ID for evernode"
                        }; then
                            for tls_file in \$user_dir/\$contract_dir/tls/*.pem; do
                                tls_newname=\$(echo \$(basename \$tls_file) | sed 's/[0-9]*//g')
                                mv "\$tls_file" "\$user_dir/\$contract_dir/tls/\$tls_newname"
                            done
                            chown -R \$user:\$user \$user_dir/\$contract_dir/tls
                            ## if [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then echo "curl -k -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID" >>$cleanup_script; fi
                            NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
                            NPM_CERT_UPDATE="false"
                        else
                            echo "failed to download and unzip certificate ID \$NPM_CERT_ID, setting up domain with no SSL."
                            echo "flushing broken ssl certificate with ID \$NPM_CERT_ID from NPMplus."
                            curl -k -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID
                            NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                        fi
                    fi
                fi

                if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" || "\$NPM_CERT_UPDATE" == "true" ]]; then
                    if [[ "\$custom_docker_domain_dns" == "dns" ]]; then
                        echo "certificate unable to be obtained, proxy will be setup with no SSL/https support."
                    else
                        echo "certificate unable to be obtained from other authorized evernodes, proxy will be setup with no SSL/https support."
                    fi

                    ## if [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then echo "curl -k -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID" >>$cleanup_script; fi
                    NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                fi
            elif [[ "\$NPM_CERT_PROVIDER" == "other" && "\$NPM_CERT_META_KEY" != "" ]]; then
                echo "found custom certificate for host domain \$custom_docker_domain, its already in date, with ID=\$NPM_CERT_ID, expiry=\$NPM_CERT_EXPIRE, WILDCARD=\$NPM_CERT_ID_WILD"
                mkdir -p \$user_dir/\$contract_dir/tls
                if [[ -z "\$custom_docker_subdomain" ]] && [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then
                    if {
                        jq -r '.certificate'     <<< "\$NPM_CERT_META" > \$user_dir/\$contract_dir/tls/cert.pem &&
                        jq -r '.certificate_key' <<< "\$NPM_CERT_META" > \$user_dir/\$contract_dir/tls/privkey.pem
                    }; then
                        echo "extracted certificate ID \$NPM_CERT_ID into /tls path"
                        chown -R \$user:\$user \$user_dir/\$contract_dir/tls
                        NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
                    else
                        echo "failed to extract certificate ID \$NPM_CERT_ID, setting up domain with no SSL."
                        NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                    fi
                else
                    echo "host wildcard tls files not added to instance, due to security."
                    NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
                fi
            elif [[ -n "\$NPM_CERT_ID" ]]; then
                echo "found existing certificate for host domain \$custom_docker_domain, with ID:\$NPM_CERT_ID, expiry=\$NPM_CERT_EXPIRE, Type:\$NPM_CERT_PROVIDER, WILDCARD:\$NPM_CERT_ID_WILD"
                mkdir -p \$user_dir/\$contract_dir/tls
                if [[ -z "\$custom_docker_subdomain" ]] && [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then
                    if { 
                        curl -k -s --output \$user_dir/\$contract_dir/tls/tls_files.zip -m 10 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID/download &&
                        unzip \$user_dir/\$contract_dir/tls/tls_files.zip -d \$user_dir/\$contract_dir/tls
                    }; then
                        echo "downloaded certificate ID \$NPM_CERT_ID for evernode"
                        for tls_file in \$user_dir/\$contract_dir/tls/*.pem; do
                            tls_newname=\$(echo \$(basename \$tls_file) | sed 's/[0-9]*//g')
                            mv "\$tls_file" "\$user_dir/\$contract_dir/tls/\$tls_newname" >/dev/null 2>&1
                        done
                        chown -R \$user:\$user \$user_dir/\$contract_dir/tls
                        ## if [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then echo "curl -k -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID" >>$cleanup_script; fi
                        NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
                    else
                        echo "failed to download and unzip certificate ID \$NPM_CERT_ID, setting up domain with no SSL."
                        NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                    fi
                else
                    echo "host wildcard tls files not added to instance, due to security."
                    NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
                fi
            fi
        else
            echo "SSL not requested. or there was an error."
            NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
        fi
        echo

        # ADD the domain to proxy_host list
        NPM_PROXYHOSTS_LIST=\$( { curl -k -s -m 100 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" \$NPM_URL/api/nginx/proxy-hosts || { echo "something went wrong getting NPM list of proxy hosts"; NPM_PROXYHOSTS_LIST={}; }; } )
        NPM_PROXYHOSTS_ID=\$( { echo "\$NPM_PROXYHOSTS_LIST" | jq -r '.[] | select(.domain_names[] == "'"\$custom_docker_domain"'") | .id' || echo ""; } )
        if [ "\$NPM_PROXYHOSTS_ID" == "" ]; then
            echo "adding new proxy host domain \$custom_docker_domain to NPMplus..."
            ## echo "(DEBUG: using NPM_CERT_ID_STRING: \$NPM_CERT_ID_STRING )"
            NPM_ADD_RESPONSE=\$( { curl -k -s -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -d '{"domain_names":["'"\${custom_docker_domain//www./}"'","www.'"\${custom_docker_domain//www./}"'"],"forward_host":"'"\$(hostname -I | xargs | cut -d' ' -f1)"'","forward_port":'"\$web_port"''"\$NPM_CERT_ID_STRING"',"npmplus_crowdsec_appsec":'"\$internal_block_exploits"',"advanced_config":"proxy_intercept_errors on;\nreset_timedout_connection on;\nerror_page 500 501 502 503 504 505 506 507 508 @drop;\nlocation @drop { return 444; }\nadd_header X-Served-By '"\$EVERNODE_HOSTNAME"';","forward_scheme":"'"\$custom_docker_domain_scheme"'"}' \$NPM_URL/api/nginx/proxy-hosts || { echo "something went wrong when adding \$custom_docker_domain proxy host"; NPM_ADD_RESPONSE="error"; }; } ) 
            NPM_ADD_RESPONSE_CHECK=\$(jq -r '.enabled // "no enabled entry"' <<< "\$NPM_ADD_RESPONSE" || echo "jq error, no json output?")
            if [[ "\$NPM_ADD_RESPONSE_CHECK" == "1" || "\$NPM_ADD_RESPONSE_CHECK" == "true" ]]; then
                echo "successfully added new proxy host to NPM with domain \$custom_docker_domain."
                NPM_PROXYHOSTS_ID=\$( echo "\$NPM_ADD_RESPONSE" | jq -r '.id')
                echo "curl -k -s -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" -H \"cookie: token=\$NPM_TOKEN\" -H \"cookie: __Host-Http-token=\$NPM_TOKEN\" \$NPM_URL/api/nginx/proxy-hosts/\$NPM_PROXYHOSTS_ID >/dev/null 2>&1" >>$cleanup_script
            else
                echo "failed to add new proxy host domain \$custom_docker_domain, this will cause issues connecting via this domain."
                echo "(DEBUG: add_response_check:\$NPM_ADD_RESPONSE_CHECK   add_response:\$NPM_ADD_RESPONSE )"
            fi
        elif [[ -z "\$custom_docker_subdomain" ]]; then
            echo "proxy host already on NPM domain \$custom_docker_domain, updating (using a NPM_CERT_ID_STRING: \$NPM_CERT_ID_STRING)..."
            NPM_EDIT_RESPONSE=\$( { curl -k -s -m 100 -X PUT -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -H "cookie: token=\$NPM_TOKEN" -H "cookie: __Host-Http-token=\$NPM_TOKEN" -d '{"domain_names":["'"\${custom_docker_domain//www./}"'","www.'"\${custom_docker_domain//www./}"'"],"forward_host":"'"\$(hostname -I | xargs | cut -d' ' -f1)"'","forward_port":'"\$web_port"''"\$NPM_CERT_ID_STRING"',"npmplus_crowdsec_appsec":'"\$internal_block_exploits"',"advanced_config":"add_header X-Served-By '"\$EVERNODE_HOSTNAME"';","forward_scheme":"'"\$custom_docker_domain_scheme"'"}' \$NPM_URL/api/nginx/proxy-hosts/\$NPM_PROXYHOSTS_ID || { echo "something went wrong when updating \$custom_docker_domain proxy host"; NPM_EDIT_RESPONSE="error"; }; })
            NPM_EDIT_RESPONSE_CHECK=\$(jq -r '.enabled // "no enabled entry"' <<< "\$NPM_EDIT_RESPONSE" || echo "jq error, no json output?")
            if [[ "\$NPM_EDIT_RESPONSE_CHECK" == "1" || "\$NPM_EDIT_RESPONSE_CHECK" == "true" ]]; then
                echo "updated proxy host with domain \$custom_docker_domain"
                echo "curl -k -s -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" -H \"cookie: token=\$NPM_TOKEN\" -H \"cookie: __Host-Http-token=\$NPM_TOKEN\" \$NPM_URL/api/nginx/proxy-hosts/\$NPM_PROXYHOSTS_ID >/dev/null 2>&1" >>$cleanup_script
            else
                echo "failed to edit/add proxy host domain \$custom_docker_domain, this will cause issues connecting via this domain."
                echo "(DEBUG add_response_check:\$NPM_EDIT_RESPONSE_CHECK    add_response:\$NPM_EDIT_RESPONSE )"
            fi
        else 
            echo "unable to setup proxy host,already exists? debug; NPM_proxyhost_ID=\$NPM_PROXYHOSTS_ID ... custom_docker_subdomain=\$custom_docker_subdomain"
        fi
      fi
    fi
elif [[ "\$tls_type" == "letsencrypt" ]]; then
    echo "todo: add support for direct nginx"
    # this can be utilized by adding nginx directly on the host, and then using the etc/nginx/site-enabled or sites-available, as well as changing how cert bot gets utilized. but its VERY possible.
    echo
elif [[ "\$tls_type" == "" ]]; then
    echo "no supporting proxy settings to handle domain management config."
    echo
elif [[ "\$tls_type" == "failed" ]]; then
    echo "custom domain checks failed."
    echo  
else
    echo "no custom domain setup triggered... "
    echo
fi
cp \$user_dir/.docker/domain_ssl_update.log \$user_dir/\$contract_dir/tls/domain_ssl_update.log 2>/dev/null

echo "............."
EOF
    chmod +x $user_dir/.docker/domain_ssl_update.sh
    chown $user:$user $user_dir/.docker/domain_ssl_update.sh

    cp /home/sashimbxrpl/.evernode-host/.host-ssl-private.key $user_dir/.docker/.ssl_private.key && chown $user:$user $user_dir/.docker/.ssl_private.key

    if [[ -n "$custom_docker_subdomain" ]]; then
        custom_docker_domain="$custom_docker_subdomain.${EVERNODE_HOSTNAME#*.}"
        echo "subdomain request detected, assigning domain as $custom_docker_domain"
    fi
    if [[ -z "$custom_docker_domain" ]]; then
        instance_slot=${user_port: -1}
        custom_docker_domain="${EVERNODE_HOSTNAME%%.*}-${instance_slot}.${EVERNODE_HOSTNAME#*.}"
        custom_docker_subdomain="${custom_docker_domain%%.*}"
        echo "no custom domain settings found, setting up a default route of, $custom_docker_domain"
    fi


else
    echo "this evernode does not have NPMplus/proxy functions."
    custom_docker_domain="not.availble.on.this.node"
fi





cat > $user_dir/.docker/env.vars <<EOF
IMAGE_DIGEST="$(cat ${img_local_tar_path}.image_digest 2>/dev/null | cut -d'@' -f2)"
HOST_DOMAIN_ADDRESS="$(jq -r ".hp.host_address | select( . != null )" "$SA_CONFIG")"
XAHAU_NODE="https://xahau.local"
CUSTOM_DOMAIN_ADDRESS="$custom_docker_domain"
RAM_QUOTA="$(( memory / 1024 / 1024 ))GB"
DISK_QUOTA="$(( disk / 1024 / 1024 ))GB"
DISK_QUOTA_BYTES=$disk
DISK_USED_BYTES=""
DISK_USED="\$(( DISK_USED_BYTES / 1024 / 1024 ))GB"
DISK_FREE="\$(( ( DISK_QUOTA_BYTES - DISK_USED_BYTES ) / 1024 / 1024 ))GB"
EXTERNAL_PEER_PORT=$peer_port
INTERNAL_PEER_PORT=$internal_peer_port
EXTERNAL_USER_PORT=$user_port
INTERNAL_USER_PORT=$internal_user_port
EXTERNAL_GPTCP1_PORT=$gp_tcp_port_start
INTERNAL_GPTCP1_PORT=$internal_gptcp1_port
EXTERNAL_GPUDP1_PORT=$gp_udp_port_start
INTERNAL_GPUDP1_PORT=$internal_gpudp1_port
EXTERNAL_GPTCP2_PORT=$((gp_tcp_port_start + 1))
INTERNAL_GPTCP2_PORT=$((internal_gptcp1_port + 1))
EXTERNAL_GPUDP2_PORT=$((gp_udp_port_start + 1))
INTERNAL_GPUDP2_PORT=$((internal_gpudp1_port + 1))
PROXY_BLOCK_EXPLOITS="$internal_block_exploits"
INTERNAL_SECURITY_LEVEL="$internal_security"
INTERNAL_SWARMUNLOCK_API="$internal_security_api"
EOF
if [[ "$internal_env_count" -ge 1 ]]; then 
    for ((env_count=1; env_count<=$internal_env_count; env_count++)); do
        env_key_name="internal_env${env_count}_key"
        echo "env_key_name found ${env_key_name}"
        if [ -n "${!env_key_name}" ]; then
            env_value_name="internal_env${env_count}_value"
            echo "entry to add ...${!env_key_name}=${!env_value_name}"
            echo "${!env_key_name}=${!env_value_name}" >> "$user_dir/.docker/env.vars"
        fi
    done
fi
chown $user:$user $user_dir/.docker/env.vars


# if there is any extra docker setting requested, build and setup re-create script and a service to start it.
if [[ "$custom_docker_settings" == "true" ]]; then
    echo "user custom docker settings detected, building docker re-create script and service"

if ! python3 -c "import nacl" 2>/dev/null; then
    echo "missing dependency "python3-nacl", installing..."
    apt-get update && apt-get install --reinstall python3-nacl && echo "python3 nacl dependency installed" || echo "failed to install nacl dependency"
fi
sudo -u $user python3 -c "import nacl; print('imported nacl for python3 OK')" || echo "failed importing python nacl dependencies"

if ! python3 -c "import cryptography" 2>/dev/null; then
    echo "missing dependency "python3-cryptography", installing..."
    apt-get update && apt-get install --reinstall python3-cryptography && echo "python3 cryptography dependency installed" || echo "failed to install cryptography dependency"
fi
sudo -u $user python3 -c "import cryptography; print('imported cryptography for python3 OK')" || echo "failed importing python cryptography dependencies"


cat > "$user_dir"/.docker/docker_recreate.sh <<EOF
#!/bin/bash

export DOCKER_HOST="unix://${user_runtime_dir}/docker.sock"
while true; do
    CONTAINER_NAME=\$(${docker_bin}/docker ps -a --format "{{.Names}}" | head -n 1)
    if [[ -z "\$CONTAINER_NAME" ]]; then 
        echo "unable to obtain the container name >\$CONTAINER_NAME, sleeping then trying again..."
        sleep 2
    else
        echo "now recreating container \$CONTAINER_NAME with added features ..."
        break
    fi
done

TIMEOUT_SECONDS=600
INSPECT_DATA=\$(${docker_bin}/docker inspect \$CONTAINER_NAME)
PORTS=\$(echo \$INSPECT_DATA | jq -r '.[0].HostConfig.PortBindings')
MOUNT_SOURCE=\$(echo \$INSPECT_DATA | jq -r '.[0].HostConfig.Mounts[0].Source')
MOUNT_TARGET=\$(echo \$INSPECT_DATA | jq -r '.[0].HostConfig.Mounts[0].Target')
IMAGE="${docker_pull_image}"
PROXY_IP="${proxy_ip:-}"
XAHAU_NODE="${XAHAU_NODE:-}"
EVRPANEL_JSON="${EVRPANEL_JSON:-{}}"
IMAGE_DIGEST="\$( cat ${img_local_tar_path}.image_digest 2>/dev/null | cut -d'@' -f2 )"
ENTRY_POINT=\$(echo \$INSPECT_DATA | jq -c '.[0].Config.Entrypoint[0]')
COMMANDS=\$(echo \$INSPECT_DATA | jq -c '.[0].Config.Cmd' | jq -r 'join(" ")')
INSTANCE_PUBLIC_KEY=\$(cat $user_dir/.docker/instance_publickey)
internal_run_contract="$internal_run_contract"
internal_dev_count=$internal_dev_count
internal_dev_values=(${internal_dev_values[*]})
internal_sec_count=$internal_sec_count
internal_sec_values=(${internal_sec_values[*]})
internal_vol_count=$internal_vol_count
internal_vol_values=(${internal_vol_values[*]})
internal_readonly="$internal_readonly"
internal_security="$internal_security"
internal_security_api="$internal_security_api"

# setup swarm lock/key if needed
if [[ "\$internal_security" == "mid" ]] || [[ "\$internal_security" == "high" ]]; then
_api_enabled="false" && _api_pubkey="" && _api_url="" && _api_container=""

if [[ "\$internal_security" == "mid" ]]; then
    _api_pubkey=\$(curl -s -m 25 "\$internal_security_api" | jq -r '.')
    if [[ "\$_api_pubkey" == *"BEGIN PUBLIC KEY"* ]]; then
        _api_enabled="true"
        _api_url="\$internal_security_api"
        _api_container="\$CONTAINER_NAME"
        echo "✅ [INFO] fetched API public key from \$_api_url" | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
    else
        echo "❌ [ERROR] could not fetch valid public key from \$internal_security_api" | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
    fi
else
    echo "❌ [INFO] not setting up API unlocking, as security set to \$internal_security." | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
fi

# python block - captures swarm key and encrypts it, uses python to prevent leaking key.
python3 - \
    "\${INSTANCE_PUBLIC_KEY:2}" \
    "\$_api_enabled" \
    "\$_api_pubkey" \
    "\$_api_url" \
    "\$_api_container" \
    "${user_dir}/.local/share/docker/swarm/certificates" \
    "$docker_bin" \
    "$user_dir" \
<<'PYEOF'
import sys, os, re, base64, subprocess, ctypes
from nacl.bindings import crypto_sign_ed25519_pk_to_curve25519, crypto_box_seal

instance_pub_hex, api_enabled, api_pubkey_pem, api_url, api_container, cert_dir, docker_bin, user_dir = sys.argv[1:9]
log_path = f"{user_dir}/.local/lib/docker/plugins/authz/authz.log"
def log(msg):
    print(msg, file=sys.stderr)
    open(log_path, "a").write(msg + "\n")
def zero(ba):
    ctypes.memset((ctypes.c_char * len(ba)).from_buffer(ba), 0, len(ba))

def security_precheck():
    # 1. Already being traced? (debugger/strace/ptrace attach)
    try:
        status = open("/proc/self/status").read()
        tracer_pid = next((line.split(":")[1].strip() for line in status.splitlines() if line.startswith("TracerPid:")), "0")
        if tracer_pid != "0":
            log(f"❌ [SECURITY] process is being traced (TracerPid={tracer_pid}); aborting"); return False
    except Exception as e: log(f"❌ [SECURITY] could not read /proc/self/status: {e}"); return False

    # 2. LD_PRELOAD set for this process?
    if os.environ.get("LD_PRELOAD"):
        log(f"❌ [SECURITY] LD_PRELOAD is set ({os.environ['LD_PRELOAD']}); aborting"); return False

    # 3. System-wide preload file in use?
    if os.path.exists("/etc/ld.so.preload") and os.path.getsize("/etc/ld.so.preload") > 0:
        log("❌ [SECURITY] /etc/ld.so.preload is non-empty; aborting"); return False

    # 4. Confirm PR_SET_DUMPABLE actually took effect, as 3 GETS/reads the setting.
    dumpable = libc.prctl(3, 0, 0, 0, 0)
    if dumpable != 0:
        log(f"❌ [SECURITY] process is still dumpable (prctl returned {dumpable}); aborting"); return False

    return True

# --- harden process before touching any secret
libc = ctypes.CDLL("libc.so.6")
libc.mlockall(3)                 # MCL_CURRENT|MCL_FUTURE — no swap
ret = libc.prctl(4, 0, 0, 0, 0)  # SETS the block on /proc/<pid>/mem + ptrace as we attach here
if ret != 0:
    log("❌ [SECURITY] failed to set PR_SET_DUMPABLE (/proc/ blocking )"); sys.exit(1)
if not security_precheck():
    log("❌ [SECURITY] failed security pre-checks"); sys.exit(1)

# --- capture swarm key inside python, as raw bytes (never touches bash/proc/logs)
try:
    docker_init = bytearray(subprocess.run([f"{docker_bin}/docker", "swarm", "init", "--autolock"], capture_output=True).stdout)
except Exception:
    log(f"❌ [ERROR] failed to execute docker swarm init."); sys.exit(1)
match = re.search(rb'(SWMKEY-1-\S+)', docker_init)
if not match: log("❌ [ERROR] could not parse swarm key"); sys.exit(1)
swm_key = bytearray(match.group(1))
zero(docker_init); del docker_init, match

# --- encrypt with instance key (NaCl sealed box)
try:
    ct = crypto_box_seal(bytes(swm_key), crypto_sign_ed25519_pk_to_curve25519(bytes.fromhex(instance_pub_hex)))
    out_path = f"{cert_dir}/swmkey_instanceKey.txt"
    open(out_path, "w").write(base64.b64encode(ct).decode())
    log("✅ [INFO] swarm key encrypted with instance public key, ready for manual unlock.")
except Exception:
    log(f"❌ [ERROR] instance key encryption failed.")

# --- encrypt with API key (RSA-OAEP) if available
if api_enabled == "true":
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        ct2 = serialization.load_pem_public_key(api_pubkey_pem.encode()).encrypt(bytes(swm_key),padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        open(f"{cert_dir}/swmkey_apiKey.txt",       "w").write(base64.b64encode(ct2).decode())
        open(f"{cert_dir}/swmkey_apiAddress.txt",   "w").write(api_url)
        open(f"{cert_dir}/swmkey_apiContainer.txt", "w").write(api_container)
        log(f"✅ [INFO] swarm key encrypted with API public key from {api_url}, ready to auto unlock.")
    except Exception:
        log(f"❌ [ERROR] API key encryption failed.")
zero(swm_key)
PYEOF
if [[ ! -f "${user_dir}/.local/share/docker/swarm/certificates/swmkey_instanceKey.txt" ]]; then
    echo "❌ [ERROR] swarm key encryption failed, instance key file missing." | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
fi

else
    echo "❌ [INFO] starting docker swarm (enables features like secrets), but as security setting is on low, --autolock is DISABLED, meaning swarm key is left totally unencrypted." | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
    ${docker_bin}/docker swarm init || echo "❌ [ERROR] docker swarm did not start." 2>&1 | tee -a "$user_dir/.local/lib/docker/plugins/authz/authz.log" >&2
fi


# Build the docker create command
docker_create_command="timeout --foreground -v -s SIGINT \${TIMEOUT_SECONDS}s ${docker_bin}/docker service create --stop-signal=SIGINT --log-driver local --log-opt max-size=5m --log-opt max-file=2 --with-registry-auth --name=\${CONTAINER_NAME::-1} --cap-add=NET_ADMIN "

# Set the ports
for port in \$(echo \$PORTS | jq -r 'to_entries | .[] | .key'); do
    external_port=\$(echo \$PORTS | jq -r ".\\"\$port\\"[0].HostPort")
    internal_port=\$port
    if [[ "${peer_port}" == "\$external_port" ]]; then internal_port="${internal_peer_port}/\${port#*/}"; fi
    if [[ "${user_port}" == "\$external_port" ]]; then internal_port="${internal_user_port}/\${port#*/}"; fi
    if [[ "${gp_tcp_port_start}" == "\$external_port" ]]; then internal_port="${internal_gptcp1_port}/\${port#*/}"; fi
    if [[ "${gp_udp_port_start}" == "\$external_port" ]]; then internal_port="${internal_gpudp1_port}/\${port#*/}"; fi
    if [[ "$((gp_tcp_port_start + 1))" == "\$external_port" ]]; then internal_port="${internal_gptcp2_port}/\${port#*/}"; fi
    if [[ "$((gp_udp_port_start + 1))" == "\$external_port" ]]; then internal_port="${internal_gpudp2_port}/\${port#*/}"; fi
    internal_port_proto="\${internal_port#*/}"
    internal_port="\${internal_port%%/*}"
    echo "EXTERNAL:\$external_port     INTERNAL:\$internal_port PROTOCOL:\$internal_port_proto"
    docker_create_command="\$docker_create_command --publish mode=host,target=\$internal_port,published=\$external_port,protocol=\$internal_port_proto"
done

# setup host settings
if [[ "\$(echo "\$EVRPANEL_JSON" | jq -r '.shareXahauNode // empty')" == "true" && "\$PROXY_IP" != "" ]]; then
    docker_create_command="\$docker_create_command --host xahau.local:\${PROXY_IP#*//}"
fi
if [[ "\$(echo "\$EVRPANEL_JSON" | jq -r '.shareXRPLNode // empty')" == "true" && "\$PROXY_IP" != "" ]]; then
    docker_create_command="\$docker_create_command --host xrpl.local:\${PROXY_IP#*//}"
fi
if [[ "\$(echo "\$EVRPANEL_JSON" | jq -r '.shareCustomHost // empty')" == "true" && "\$(echo "\$EVRPANEL_JSON" | jq -r '.shareXahauNode // empty')" != "" && "\$PROXY_IP" != "" ]]; then
    docker_create_command="\$docker_create_command --host \$(echo "\$EVRPANEL_JSON" | jq -r '.customHostDomain // empty'):\${PROXY_IP#*//}"
fi

# prevents direct admin access to the evernodes Xahau node.
[[ "\$XAHAU_NODE" =~ ^([0-9]+\.){3}[0-9]+$ ]] || docker_create_command="\$docker_create_command --host \$XAHAU_NODE:0.0.0.0"

# Add Environment variables
docker_create_command="\$docker_create_command --env-file $user_dir/.docker/env.vars"

# Add Devices if needed
if [[ "\$internal_dev_count" -ge 1 ]]; then 
    echo "setting up dev \$internal_dev_count value(s), \${internal_dev_values[*]}"
    for ((dev_count=0; dev_count<=\$internal_dev_count; dev_count++)); do
        if [ -n "\${internal_dev_values[\$dev_count]}" ]; then
            docker_create_command="\$docker_create_command --device=/dev/\${internal_dev_values[\$dev_count]}"
            echo "device /dev/\${internal_dev_values[\$dev_count]} added."
        fi
    done
fi

# Add Secrets if needed
if [[ "\$internal_sec_count" -ge 1 ]]; then 
    for sec_name in "\${internal_sec_values[@]}"; do
        if [ -n "\$sec_name" ]; then
            docker_create_command="\$docker_create_command --secret \$sec_name"
            printf "%s" "placeholder-only" | ${docker_bin}/docker secret create \$sec_name - || true
            echo "secret \${sec_name} created and placeholder added."
        fi
    done
fi

# Add restart policy
docker_create_command="\$docker_create_command --restart-condition any"

# Add security options
#docker_create_command="\$docker_create_command --security-opt seccomp=unconfined --security-opt apparmor=unconfined" # removed as conflicts with "service create" need to move to docker-compose.yml

if [[ "\$internal_readonly" == "true" ]]; then
    docker_create_command="\$docker_create_command --read-only "
fi

# Add volume binding
docker_create_command="\$docker_create_command --mount type=bind,source=\${MOUNT_SOURCE},target=\${MOUNT_TARGET}"
docker_create_command="\$docker_create_command --mount type=volume,source=home,target=/home"
if [[ "\$internal_vol_count" -ge 1 ]]; then 
    vol_count=1
    for vol in "\${internal_vol_values[@]}"; do
        if [[ "\${vol}" != "home" ]] || [[ "\${vol}" != "contract" ]]; then
            docker_create_command="\$docker_create_command --mount type=volume,source=vol\${vol_count},target=/\${vol}"
        fi
        ((vol_count++))
    done
fi

# Handle entry point and commands
if [[ -n "\$ENTRY_POINT" ]] && [[ "\${internal_run_contract}" != "false" ]]; then
    docker_create_command="\$docker_create_command --entrypoint \${ENTRY_POINT} "
fi
if [[ "\${internal_run_contract}" != "" ]]; then
    COMMANDS="\$internal_run_contract"
fi
if [[ "\${internal_run_contract}" == "false" ]]; then
    COMMANDS=""
fi

# handle original container, and service
${docker_bin}/docker stop \$CONTAINER_NAME
${docker_bin}/docker rm \$CONTAINER_NAME

# Execute the docker create command
echo "docker_create_command built, lets run >\$docker_create_command \${IMAGE}@\${IMAGE_DIGEST} \${COMMANDS}"
\$docker_create_command \${IMAGE} \${COMMANDS}
#${docker_bin}/docker start \$CONTAINER_NAME 
EOF
chmod +x "$user_dir"/.docker/docker_recreate.sh

## Docker compose method, not used as didnt support all features like secrets as still needed to be generated etc, left here as a useful reminder !
# cat > "$user_dir"/.docker/docker_recreate.sh <<EOF
# #!/bin/bash
# export DOCKER_HOST="unix://${user_runtime_dir}/docker.sock"

# # Wait for old container name
# while true; do
#     CONTAINER_NAME=\$(${docker_bin}/docker ps -a --format "{{.Names}}" | head -n 1)
#     if [[ -z "\$CONTAINER_NAME" ]]; then 
#         echo "Waiting for container name..."
#         sleep 3
#     else
#         echo "Found container \$CONTAINER_NAME – recreating with compose..."
#         sleep 5
#         break
#     fi
# done

# # Inspect old container
# INSPECT_DATA=\$(${docker_bin}/docker inspect "\$CONTAINER_NAME")
# PORTS=\$(echo "\$INSPECT_DATA" | jq -r '.[0].HostConfig.PortBindings // empty')
# MOUNT_SOURCE=\$(echo "\$INSPECT_DATA" | jq -r '.[0].HostConfig.Mounts[0].Source')
# MOUNT_TARGET=\$(echo "\$INSPECT_DATA" | jq -r '.[0].HostConfig.Mounts[0].Target')
# IMAGE=\$(echo "\$INSPECT_DATA" | jq -r '.[0].Config.Image')

# # Your variables (will be expanded from the parent context when this script runs)
# internal_dev_count=$internal_dev_count
# internal_dev_values=(${internal_dev_values[@]})
# internal_sec_count=$internal_sec_count
# internal_sec_values=(${internal_sec_values[@]})
# internal_vol_count=$internal_vol_count
# internal_vol_values=(${internal_vol_values[@]})
# internal_readonly="$internal_readonly"
# internal_run_contract="$internal_run_contract"

# # Ensure swarm
# \$(${docker_bin}/docker swarm init >/dev/null 2>&1 || true )

# # Generate compose.yml
# COMPOSE_FILE="$user_dir/.docker/compose.yml"
# cat > "\$COMPOSE_FILE" <<COMPOSE_EOF
# version: "3.8"

# services:
#   instance:
#     image: \$IMAGE
#     container_name: \${CONTAINER_NAME::-1}
#     stop_signal: SIGINT
#     cap_add:
#       - NET_ADMIN
#     logging:
#       driver: local
#       options:
#         max-size: "5m"
#         max-file: "2"
#     env_file:
#       - $user_dir/.docker/env.vars
#     restart: unless-stopped
#     read_only: \$internal_readonly
# COMPOSE_EOF

# # Ports (host mode)
# if [[ -n "\$PORTS" ]]; then
#     echo "    ports:" >> "\$COMPOSE_FILE"
#     for port in \$(echo "\$PORTS" | jq -r 'to_entries | .[] | .key'); do
#         external_port=\$(echo "\$PORTS" | jq -r ".[\\"\$port\\"][0].HostPort")
#         internal_port="\${port%/*}"
#         proto="\${port#*/}"
#         cat >> "\$COMPOSE_FILE" <<PORT_EOF
#       - mode: host
#         target: \$internal_port
#         published: \$external_port
#         protocol: \$proto
# PORT_EOF
#     done
# fi

# # Devices
# if [[ "\$internal_dev_count" -ge 1 ]]; then
#     echo "    devices:" >> "\$COMPOSE_FILE"
#     for dev in "\${internal_dev_values[@]}"; do
#         [[ -n "\$dev" ]] && echo "      - /dev/\$dev:/dev/\$dev" >> "\$COMPOSE_FILE"
#     done
# fi

# # Volume
# cat >> "\$COMPOSE_FILE" <<VOL_EOF
#     volumes:
#       - \$MOUNT_SOURCE:\$MOUNT_TARGET
# VOL_EOF
# if [[ "\$internal_vol_count" -ge 1 ]]; then 
#     for vol in "\${internal_vol_values[@]}"; do
#         [[ -n "\$vol" ]] && echo "      - \$vol:\$vol" >> "\$COMPOSE_FILE"
#     done
# fi

# # Secrets reference
# if [[ "\$internal_sec_count" -ge 1 ]]; then
#     echo "    secrets:" >> "\$COMPOSE_FILE"
#     for sec_name in "\${internal_sec_values[@]}"; do
#         if [ -n "\$sec_name" ]; then
#             echo "      - \$sec_name" >> "\$COMPOSE_FILE"
#             printf "%s" "placeholder-only" | ${docker_bin}/docker secret create \$sec_name - || true
#             echo "secret \${sec_name} created and placeholder added."
#         fi
#     done
# fi

# # Secrets block at the end
# if [[ "\$internal_sec_count" -ge 1 ]]; then
#     echo "" >> "\$COMPOSE_FILE"
#     echo "secrets:" >> "\$COMPOSE_FILE"
#     for sec_names in "\${internal_sec_values[@]}"; do
#         if [ -n "\$sec_names" ]; then
#             echo "  \$sec_names:" >> "\$COMPOSE_FILE"
#             echo "    external: true" >> "\$COMPOSE_FILE"
#         fi
#     done
# fi

# # Optional: override command if you have a contract
# if [[ -n "\$internal_run_contract" ]]; then
#     echo "    command: \$internal_run_contract" >> "\$COMPOSE_FILE"
# fi

# # Clean up old container
# \$(${docker_bin}/docker stop "\$CONTAINER_NAME" >/dev/null 2>&1 || true )
# \$(${docker_bin}/docker rm "\$CONTAINER_NAME" >/dev/null 2>&1 || true )

# # Deploy
# echo "Deploying with docker compose..."
# cd "$user_dir/.docker"
# ${docker_bin}docker stack deploy -c \$COMPOSE_FILE $user
# #${docker_bin}/docker compose up -d --remove-orphans && echo "Service recreated successfully..."
# EOF
# chmod +x "$user_dir"/.docker/docker_recreate.sh


quota_crontab_awk_cmd="awk ''\'NR==3 {print \\\\\$2}''\'"
quota_crontab_sed_cmd='sed \\"s/^DISK_USED_BYTES=.*/DISK_USED_BYTES=\\$USED_BYTES/\\"'
quota_crontab_entry='echo "*/30 * * * * USED_BYTES=\\$(quota -u '${user}' 2>/dev/null | '${quota_crontab_awk_cmd}' || echo \\"0\\") && '${quota_crontab_sed_cmd}' \\"'${user_dir}'/'${contract_dir}'/env.vars\\" > \\"'${user_dir}'/'${contract_dir}'/env.vars.tmp\\" && [ -s '${user_dir}'/'${contract_dir}'/env.vars.tmp ] && mv \\"'${user_dir}'/'${contract_dir}'/env.vars.tmp\\" \\"'${user_dir}'/'${contract_dir}'/env.vars\\"" | crontab -'
domain_ssl_update_1='(crontab -l 2>/dev/null; echo "0 0 */4 * * sleep \\$((RANDOM % 3600)); /usr/bin/bash '${user_dir}'/.docker/domain_ssl_update.sh 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log") | crontab -'
domain_ssl_update_2='bash "'${user_dir}'/.docker/domain_ssl_update.sh" 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log'

cat > "$user_dir"/.config/systemd/user/docker_recreate.service <<EOF
[Unit]
Description=Docker Create Event Watcher
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=no
ExecStart=/bin/bash -c ' \\
  DOCKER_HOST="unix://${user_runtime_dir}/docker.sock" ${docker_bin}/docker events --filter event=create |\\
  while read -r create_event; do \\
    echo "Handling event: \${create_event}" >> "${user_dir}/.docker/docker_recreate.log"; \\
    echo "\$(jq -r ".contract.bin_args | select( . != null )" "${user_dir}/${contract_dir}/cfg/hp.cfg")" >> ${user_dir}/.docker/instance_publickey; \\
    echo "INSTANCE_PUBKEY=\$(cat ${user_dir}/.docker/instance_publickey)" | tee -a ${user_dir}/.docker/env.vars; \\
    cp ${user_dir}/.docker/env.vars ${user_dir}/${contract_dir}/env.vars; \\
    ${quota_crontab_entry}; \\
    ${domain_ssl_update_1}; \\
    ${domain_ssl_update_2}; \\
    bash "${user_dir}/.docker/docker_recreate.sh" 2>&1 | tee -a ${user_dir}/.docker/docker_recreate.log; \\
    break; \\
  done'
SuccessExitStatus=0 143

[Install]
WantedBy=default.target
EOF


sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user daemon-reload
##sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user enable docker_recreate.service
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user start docker_recreate.service
echo "sudo -u \"$user\" XDG_RUNTIME_DIR=\"$user_runtime_dir\" systemctl --user stop docker_recreate.service" >>$cleanup_script
echo "sudo -u \"$user\" XDG_RUNTIME_DIR=\"$user_runtime_dir\" systemctl --user disable docker_recreate.service" >>$cleanup_script
echo "crontab -u $user -r" >>$cleanup_script
echo "sudo nft flush table ip docker_filter_$user_id 2>/dev/null && sudo nft delete table ip docker_filter_$user_id 2>/dev/null && echo \"Cleaned up docker_filter_$user_id table\"" >>$cleanup_script
echo "nft list ruleset > /etc/nftables.conf" >>$cleanup_script
echo "cat $user_dir/.docker/domain_ssl_update.log >> /root/domain_ssl_update.log" >>$cleanup_script
chown -R $user:$user $cleanup_script

else
    echo "no user custom docker settings detected, only adding env.vars file and quota system."
    quota_crontab_awk_cmd="awk ''\'NR==3 {print \\\\\$2}''\'"
    quota_crontab_sed_cmd='sed \\"s/^DISK_USED_BYTES=.*/DISK_USED_BYTES=\\$USED_BYTES/\\"'
    quota_crontab_entry='echo "*/30 * * * * USED_BYTES=\\$(quota -u '${user}' 2>/dev/null | '${quota_crontab_awk_cmd}' || echo \\"0\\") && '${quota_crontab_sed_cmd}' \\"'${user_dir}'/'${contract_dir}'/env.vars\\" > \\"'${user_dir}'/'${contract_dir}'/env.vars.tmp\\" && [ -s '${user_dir}'/'${contract_dir}'/env.vars.tmp ] && mv \\"'${user_dir}'/'${contract_dir}'/env.vars.tmp\\" \\"'${user_dir}'/'${contract_dir}'/env.vars\\"" | crontab -'
    echo "no custom port or other user settings found. setting up recreate service to copy .vars file and default domain-farwading/proxy-host"
    if [[ "$TLS_TYPE" == "NPMplus" ]] && [[ "$docker_pull_image" != *"reputation"* ]]; then
        domain_ssl_update_1='(crontab -l 2>/dev/null; echo "0 0 */4 * * sleep \\$((RANDOM % 3600)); /usr/bin/bash '${user_dir}'/.docker/domain_ssl_update.sh 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log") | crontab -'
        domain_ssl_update_2='bash "'${user_dir}'/.docker/domain_ssl_update.sh" 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log'
    else
        domain_ssl_update_1='echo "NPMplus NOT intalled on host,"'
        domain_ssl_update_2='echo "or reputation contract detected."'
    fi

# set up a service to copy in the .vars file AFTER docker has created the original container. (as container/image needs to be created, before we can copy it in)
cat > "$user_dir"/.config/systemd/user/docker_vars.service <<EOF
[Unit]
Description=Docker env.vars file setup, and proxy support.
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
ExecStart=/bin/bash -c ' \\
  DOCKER_HOST="unix://${user_runtime_dir}/docker.sock" ${docker_bin}/docker events --filter event=create | \\
  while read -r create_event; do \\
    cp "${user_dir}/.docker/env.vars" "${user_dir}/${contract_dir}/env.vars"; \\
    ${quota_crontab_entry}; \\
    ${domain_ssl_update_1}; \\
    ${domain_ssl_update_2}; \\
    break; \\
  done'
SuccessExitStatus=0 143

[Install]
WantedBy=default.target
EOF

    sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user daemon-reload
    sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user enable docker_vars.service
    sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user start docker_vars.service
    echo "sudo -u \"$user\" XDG_RUNTIME_DIR=\"$user_runtime_dir\" systemctl --user stop docker_vars.service" >>$cleanup_script
    echo "sudo -u \"$user\" XDG_RUNTIME_DIR=\"$user_runtime_dir\" systemctl --user disable docker_vars.service" >>$cleanup_script
    echo "crontab -u $user -r" >>$cleanup_script
    echo "sudo nft flush table ip docker_filter_$user_id 2>/dev/null && sudo nft delete table ip docker_filter_$user_id 2>/dev/null && echo \"Cleaned up docker_filter_$user_id table\"" >>$cleanup_script
    echo "nft list ruleset > /etc/nftables.conf" >>$cleanup_script
    echo "cat $user_dir/.docker/domain_ssl_update.log >> /root/domain_ssl_update.log" >>$cleanup_script
    chown -R $user:$user $cleanup_script

fi

# save and make sure nft tables service persist after a restart
nft list ruleset > /etc/nftables.conf
systemctl enable nftables
systemctl daemon-reload

echo "$user_id,$user,$dockerd_socket,INST_SUC"
exit 0
