#!/bin/bash
# magma AGW docker install script - docker compose v2 compatible
#
# improvements over original magma script:
# - does not hardcode MAGMA_USER=ubuntu
# - uses Docker Compose v2: docker compose
# - preserves host networking by default
# - makes legacy networking optional
# - separates OS networking from Magma config reconciliation
# - detects or accepts real interface names
# - reconciles generated Magma configs after Ansible
# - replaces legacy eth0/eth1 assumptions when networking is preserved
# - patches mme.yml, spgw.yml, pipelined.yml, and all generated config files
# - avoids partial/minimal mme.yml generation
# - checks kernel compatibility before DKMS can break install

set -euo pipefail

MODE="${1:-}"
RERUN="${RERUN:-0}"

MAGMA_VERSION="${MAGMA_VERSION:-v1.8}"
GIT_URL="${GIT_URL:-https://github.com/magma/magma.git}"

MAGMA_ROOT="${MAGMA_ROOT:-/opt/magma}"
DEPLOY_PATH="$MAGMA_ROOT/lte/gateway/deploy"
ROOTCA="${ROOTCA:-/var/opt/magma/certs/rootCA.pem}"

CONFIGURE_NETWORKING="${CONFIGURE_NETWORKING:-false}"
PATCH_MAGMA_CONFIGS="${PATCH_MAGMA_CONFIGS:-true}"
ALLOW_UNSUPPORTED_KERNEL="${ALLOW_UNSUPPORTED_KERNEL:-false}"

AGW_NAT_IFACE="${AGW_NAT_IFACE:-}"
AGW_LAN_IFACE="${AGW_LAN_IFACE:-}"
AGW_LAN_IP="${AGW_LAN_IP:-}"

LEGACY_NAT_IFACE="${LEGACY_NAT_IFACE:-eth0}"
LEGACY_LAN_IFACE="${LEGACY_LAN_IFACE:-eth1}"

MAGMA_USER="${MAGMA_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo root)}}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "INFO: $*"
}

warn() {
  echo "WARNING: $*" >&2
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run this script with sudo."
}

detect_default_route_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

detect_lan_iface() {
  local default_iface="$1"

  ip -o -4 addr show scope global | awk -v def="$default_iface" '
    {
      split($4, ipcidr, "/")
      iface=$2
      ip=ipcidr[1]
      if (iface != def && ip !~ /^127\./) {
        print iface
        exit
      }
    }
  '
}

detect_iface_ip() {
  local iface="$1"

  ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '
    {
      split($4, ipcidr, "/")
      print ipcidr[1]
      exit
    }
  '
}

detect_or_validate_interfaces() {
  local default_iface

  default_iface="$(detect_default_route_iface || true)"

  if [ -z "$AGW_NAT_IFACE" ]; then
    AGW_NAT_IFACE="$default_iface"
  fi

  if [ -z "$AGW_LAN_IFACE" ]; then
    AGW_LAN_IFACE="$(detect_lan_iface "$AGW_NAT_IFACE" || true)"
  fi

  if [ -z "$AGW_LAN_IP" ] && [ -n "$AGW_LAN_IFACE" ]; then
    AGW_LAN_IP="$(detect_iface_ip "$AGW_LAN_IFACE" || true)"
  fi

  [ -n "$AGW_NAT_IFACE" ] || die "Could not detect NAT/default interface. Set AGW_NAT_IFACE manually."
  [ -n "$AGW_LAN_IFACE" ] || die "Could not detect AGW LAN/internal interface. Set AGW_LAN_IFACE manually."
  [ -n "$AGW_LAN_IP" ] || die "Could not detect AGW LAN/internal IP. Set AGW_LAN_IP manually."

  ip link show "$AGW_NAT_IFACE" >/dev/null 2>&1 || die "NAT interface not found: $AGW_NAT_IFACE"
  ip link show "$AGW_LAN_IFACE" >/dev/null 2>&1 || die "LAN interface not found: $AGW_LAN_IFACE"

  info "Selected NAT/default interface: $AGW_NAT_IFACE"
  info "Selected AGW LAN interface    : $AGW_LAN_IFACE"
  info "Selected AGW LAN IP           : $AGW_LAN_IP"
}

replace_or_append_yaml_key() {
  local file="$1"
  local key="$2"
  local value="$3"

  [ -f "$file" ] || touch "$file"

  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}:.*|${key}: ${value}|" "$file"
  else
    printf "\n%s: %s\n" "$key" "$value" >> "$file"
  fi
}

replace_legacy_interfaces_in_file() {
  local file="$1"

  [ -f "$file" ] || return 0

  sed -i \
    -e "s/\"${LEGACY_NAT_IFACE}\"/\"${AGW_NAT_IFACE}\"/g" \
    -e "s/'${LEGACY_NAT_IFACE}'/'${AGW_NAT_IFACE}'/g" \
    -e "s/: ${LEGACY_NAT_IFACE}\([[:space:]#]\|$\)/: ${AGW_NAT_IFACE}\1/g" \
    -e "s/= ${LEGACY_NAT_IFACE}\([[:space:]#]\|$\)/= ${AGW_NAT_IFACE}\1/g" \
    -e "s/${LEGACY_NAT_IFACE}:/${AGW_NAT_IFACE}:/g" \
    -e "s/\"${LEGACY_LAN_IFACE}\"/\"${AGW_LAN_IFACE}\"/g" \
    -e "s/'${LEGACY_LAN_IFACE}'/'${AGW_LAN_IFACE}'/g" \
    -e "s/: ${LEGACY_LAN_IFACE}\([[:space:]#]\|$\)/: ${AGW_LAN_IFACE}\1/g" \
    -e "s/= ${LEGACY_LAN_IFACE}\([[:space:]#]\|$\)/= ${AGW_LAN_IFACE}\1/g" \
    -e "s/${LEGACY_LAN_IFACE}:/${AGW_LAN_IFACE}:/g" \
    "$file"
}

restore_config_from_template_if_missing() {
  local service="$1"
  local config="/var/opt/magma/configs/${service}.yml"
  local template="$MAGMA_ROOT/lte/gateway/configs/${service}.yml"

  mkdir -p /var/opt/magma/configs

  if [ ! -f "$config" ] && [ -f "$template" ]; then
    info "${service}.yml missing. Restoring from template."
    cp "$template" "$config"
  fi
}

restore_mme_if_incomplete() {
  local config="/var/opt/magma/configs/mme.yml"
  local template="$MAGMA_ROOT/lte/gateway/configs/mme.yml"

  [ -f "$template" ] || {
    warn "MME template not found: $template"
    return 0
  }

  if [ ! -f "$config" ]; then
    info "mme.yml missing. Restoring from template."
    cp "$template" "$config"
    return 0
  fi

  local line_count
  line_count="$(wc -l < "$config")"

  if [ "$line_count" -lt 40 ]; then
    warn "mme.yml appears incomplete. Backing it up and restoring full template."
    cp "$config" "${config}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$template" "$config"
  fi
}

patch_known_agw_config_keys() {
  local mme="/var/opt/magma/configs/mme.yml"
  local spgw="/var/opt/magma/configs/spgw.yml"
  local pipelined="/var/opt/magma/configs/pipelined.yml"

  restore_mme_if_incomplete
  restore_config_from_template_if_missing "spgw"
  restore_config_from_template_if_missing "pipelined"

  if [ -f "$mme" ]; then
    replace_or_append_yaml_key "$mme" "enable_nat" "true"
    replace_or_append_yaml_key "$mme" "nat_iface" "\"$AGW_NAT_IFACE\""
    replace_or_append_yaml_key "$mme" "s11_iface_name" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$mme" "s1ap_iface_name" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$mme" "gtpu_iface_name" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$mme" "s1u_iface_name" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$mme" "s1ap_ipv6_enabled" "false"
  fi

  if [ -f "$spgw" ]; then
    replace_or_append_yaml_key "$spgw" "s11_iface_name" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$spgw" "s1u_iface_name" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$spgw" "sgi_management_iface" "\"$AGW_NAT_IFACE\""
    replace_or_append_yaml_key "$spgw" "sgw_s5s8_up_iface_name" "\"$AGW_NAT_IFACE\""
    replace_or_append_yaml_key "$spgw" "sgw_s5s8_up_iface_name_non_nat" "\"$AGW_LAN_IFACE\""
  fi

  if [ -f "$pipelined" ]; then
    replace_or_append_yaml_key "$pipelined" "nat_iface" "\"$AGW_NAT_IFACE\""
    replace_or_append_yaml_key "$pipelined" "uplink_iface" "\"$AGW_LAN_IFACE\""
    replace_or_append_yaml_key "$pipelined" "clean_restart" "true"
  fi
}

reconcile_magma_configs_with_host_networking() {
  info "Reconciling Magma configs with actual host interface names"

  detect_or_validate_interfaces

  mkdir -p /var/opt/magma/configs

  # first patch known keys.
  patch_known_agw_config_keys

  # then replace legacy eth0/eth1 assumptions across generated configs
  while IFS= read -r -d '' file; do
    replace_legacy_interfaces_in_file "$file"
  done < <(find /var/opt/magma/configs -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.conf" \) -print0)

  info "Checking for remaining legacy interface references in /var/opt/magma/configs"
  if grep -RInE "(\"${LEGACY_NAT_IFACE}\"|\"${LEGACY_LAN_IFACE}\"|'${LEGACY_NAT_IFACE}'|'${LEGACY_LAN_IFACE}'|:[[:space:]]*${LEGACY_NAT_IFACE}([[:space:]#]|$)|:[[:space:]]*${LEGACY_LAN_IFACE}([[:space:]#]|$))" /var/opt/magma/configs 2>/dev/null; then
    warn "Some legacy interface references remain. Review the lines above."
  else
    info "No obvious legacy $LEGACY_NAT_IFACE/$LEGACY_LAN_IFACE references remain in config files."
  fi
}

require_root

[ -f /etc/os-release ] || die "/etc/os-release not found."
. /etc/os-release

[ "${ID:-}" = "ubuntu" ] || die "This script expects Ubuntu."

UBUNTU_VERSION="${VERSION_ID:-unknown}"
KERNEL_VERSION="$(uname -r)"
KERNEL_MAJOR="$(echo "$KERNEL_VERSION" | cut -d. -f1)"
KERNEL_MINOR="$(echo "$KERNEL_VERSION" | cut -d. -f2)"

echo "======================================================"
echo " Magma AGW Docker Installer - Compose v2"
echo "======================================================"
echo "Running as              : $(whoami)"
echo "Detected AGW user       : $MAGMA_USER"
echo "Ubuntu version          : $UBUNTU_VERSION"
echo "Kernel version          : $KERNEL_VERSION"
echo "Magma version           : $MAGMA_VERSION"
echo "Magma install path      : $MAGMA_ROOT"
echo "Configure networking    : $CONFIGURE_NETWORKING"
echo "Patch Magma configs     : $PATCH_MAGMA_CONFIGS"
echo "======================================================"

if [ "$UBUNTU_VERSION" != "20.04" ]; then
  warn "Magma AGW v1.8 is primarily expected on Ubuntu 20.04. Detected: $UBUNTU_VERSION"
fi

if [ "$KERNEL_MAJOR" -gt 5 ] || { [ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -gt 8 ]; }; then
  echo "ERROR: Kernel $KERNEL_VERSION may be incompatible with Magma AGW OVS DKMS."
  echo "Recommended: Ubuntu 20.04 GA kernel 5.4.x."
  echo "To continue anyway:"
  echo "  sudo ALLOW_UNSUPPORTED_KERNEL=true $0"
  if [ "$ALLOW_UNSUPPORTED_KERNEL" != "true" ]; then
    exit 1
  fi
  warn "Continuing with unsupported kernel because ALLOW_UNSUPPORTED_KERNEL=true."
fi

[ "$MAGMA_USER" != "root" ] || die "Run script via sudo from a normal user."
id "$MAGMA_USER" >/dev/null 2>&1 || die "User does not exist: $MAGMA_USER"

[ -f "$ROOTCA" ] || die "Missing rootCA at $ROOTCA"

if [ "$RERUN" -eq 0 ]; then
  info "Updating DNS resolvers"
  ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf || true
  sed -i 's/#DNS=/DNS=8.8.8.8 208.67.222.222/' /etc/systemd/resolved.conf || true
  systemctl restart systemd-resolved || service systemd-resolved restart || true

  info "Disabling unattended upgrades"
  echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

  cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

  apt-get purge --auto-remove unattended-upgrades -y || true

  info "Holding current kernel packages"
  apt-mark hold "$(uname -r)" linux-aws linux-headers-aws linux-image-aws || true

  if [ "$CONFIGURE_NETWORKING" = "true" ]; then
    info "Applying legacy AGW networking changes"

    mkdir -p /etc/network/interfaces.d
    echo "source-directory /etc/network/interfaces.d" > /etc/network/interfaces

    systemctl unmask networking || true
    systemctl enable networking || true

    sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/g' /etc/default/grub || true

    if [ -f /etc/netplan/50-cloud-init.yaml ]; then
      sed -i 's/ens5/eth0/g; s/ens6/eth1/g' /etc/netplan/50-cloud-init.yaml || true
    fi

    update-grub2 || true
    netplan apply || true
  else
    info "Skipping host networking changes"
  fi

  info "Installing packages"
  apt-get update -y
  apt-get upgrade -y

  apt-get install -y \
    curl \
    zip \
    git \
    python3-pip \
    net-tools \
    iproute2 \
    sudo \
    ca-certificates \
    gnupg \
    lsb-release

  info "Checking Docker"

  if command -v docker >/dev/null 2>&1; then
    docker --version
  else
    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y

    apt-get install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
  fi

  if docker compose version >/dev/null 2>&1; then
    docker compose version
  else
    apt-get update -y
    apt-get install -y docker-compose-plugin
    docker compose version
  fi

  info "Adding user to sudo and docker groups"
  usermod -aG sudo "$MAGMA_USER"
  usermod -aG docker "$MAGMA_USER"

  SUDOERS_FILE="/etc/sudoers.d/magma-agw-$MAGMA_USER"
  echo "$MAGMA_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"

  info "Installing Ansible"
  if command -v ansible-playbook >/dev/null 2>&1; then
    ansible-playbook --version | head -n 1
  else
    if [ "$UBUNTU_VERSION" = "24.04" ]; then
      pip3 install --break-system-packages ansible==5.0.1 || apt-get install -y ansible
    elif [ "$UBUNTU_VERSION" = "22.04" ]; then
      pip3 install ansible==5.0.1 || pip3 install --break-system-packages ansible==5.0.1 || apt-get install -y ansible
    else
      pip3 install ansible==5.0.1 || apt-get install -y ansible
    fi
  fi

  info "Cloning Magma"
  rm -rf "$MAGMA_ROOT"
  git clone "$GIT_URL" "$MAGMA_ROOT"

  cd "$MAGMA_ROOT"
  git checkout "$MAGMA_VERSION"
fi

[ -d "$DEPLOY_PATH" ] || die "Deploy path not found: $DEPLOY_PATH"

info "Generating localhost Ansible host file"

cat > "$DEPLOY_PATH/agw_hosts" << EOF
[agw_docker]
127.0.0.1 ansible_connection=local
EOF

chown -R "$MAGMA_USER:$MAGMA_USER" "$MAGMA_ROOT" || true

info "Running AGW Ansible playbook"

if [ "$MODE" = "base" ]; then
  su - "$MAGMA_USER" -c "sudo ansible-playbook -v -e \"MAGMA_ROOT='$MAGMA_ROOT' OUTPUT_DIR='/tmp'\" -i '$DEPLOY_PATH/agw_hosts' --tags base '$DEPLOY_PATH/magma_docker.yml'"
else
  su - "$MAGMA_USER" -c "sudo ansible-playbook -v -e \"MAGMA_ROOT='$MAGMA_ROOT' OUTPUT_DIR='/tmp'\" -i '$DEPLOY_PATH/agw_hosts' --tags agwc '$DEPLOY_PATH/magma_docker.yml'"
fi

if [ "$PATCH_MAGMA_CONFIGS" = "true" ]; then
  reconcile_magma_configs_with_host_networking
else
  info "Skipping Magma config reconciliation"
fi

echo "======================================================"
echo " AGW install completed"
echo "======================================================"
echo "Summary:"
echo "1. User: $MAGMA_USER"
echo "2. Docker Compose v2 used"
echo "3. Host networking preserved: $([ "$CONFIGURE_NETWORKING" = "false" ] && echo yes || echo no)"
echo "4. Magma configs reconciled: $PATCH_MAGMA_CONFIGS"
echo "5. NAT interface: ${AGW_NAT_IFACE:-unknown}"
echo "6. LAN interface: ${AGW_LAN_IFACE:-unknown}"
echo "7. LAN IP: ${AGW_LAN_IP:-unknown}"
echo ""
echo "Recommended:"
echo "  sudo reboot"
echo "======================================================"
