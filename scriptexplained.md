
# Explanation of My AGW Docker Install Script Modifications

I modified the original Magma AGW Docker install script to make it safer, more flexible, and compatible with my Docker Compose v2-based setup.

The original script assumed older deployment conditions. It hardcoded the user as `ubuntu`, installed legacy `docker-compose`, changed host networking automatically, assumed interface names like `eth0` and `eth1`, and did not protect against kernel compatibility problems.

My newer script keeps the same basic goal:

> install and configure Magma AGW using Docker

But I changed how it does that so it works better for my VM-based lab setup.

---

## 1. I Removed the Hardcoded `ubuntu` User

### Original behavior

The original script had:

```bash
MAGMA_USER="ubuntu"
````

This meant the script always expected a user named `ubuntu`.

### Problem I faced

In my VirtualBox VM, I was using a different user, such as:

```Bash
vboxuser
```

The original script created or used an `ubuntu` user, which caused confusion because I was not logging in as that user. It also made the VM look like it had an unexpected extra login profile.

### My modification

In the new script, I changed it to detect the real user:

```Bash
MAGMA_USER="${MAGMA_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo root)}}"
```

### Why I did this

I wanted the script to use the actual user who ran `sudo`, instead of forcing everything into a hardcoded `ubuntu` account.

Now, if I run:

```Bash
sudo ./agw_install_docker_compose_v2.sh
```

the script detects my normal user and uses that user for Ansible, Docker permissions, and sudo permissions.

### How someone else can customize it

A person can still force a specific user like this:

```Bash
sudo MAGMA_USER=myuser ./agw_install_docker_compose_v2.sh
```

* * *

## 2. I Added Safer Bash Settings

### New script behavior

I added:

```Bash
set -euo pipefail
```

### Why I added this

This makes the script fail earlier and more clearly when something goes wrong.

It helps catch:

* unset variables
* failed commands
* broken command pipelines

This is useful because AGW installation can break silently if one command fails but the script keeps going.

* * *

## 3. I Made Docker Compose v2 the Default

### Original behavior

The original script installed:

```Bash
docker-compose
```

This refers to the older Compose v1 style command:

```Bash
docker-compose
```

### Problem I faced

My system had modern Docker with Compose v2, which uses:

```Bash
docker compose
```

not:

```Bash
docker-compose
```

This mismatch caused confusion because the old script expected the old standalone binary.

### My modification

The new script checks Docker and Docker Compose v2:

```Bash
if docker compose version >/dev/null 2>&1; then
  docker compose version
else
  apt-get update -y
  apt-get install -y docker-compose-plugin
  docker compose version
fi
```

### Why I did this

I wanted the script to work with modern Docker installations where Compose is installed as a Docker plugin.

### How someone can use it

They do not need to manually install old `docker-compose`.

They can install modern Docker Engine and Compose v2, then run the script normally:

```Bash
sudo ./agw_install_docker_compose_v2.sh
```

* * *

## 4. I Changed Docker Installation Logic

### Original behavior

The original script installed Docker from Ubuntu packages:

```Bash
apt-get install curl zip python3-pip docker.io net-tools sudo docker-compose -y
```

### My modification

The new script first checks whether Docker already exists:

```Bash
if command -v docker >/dev/null 2>&1; then
  docker --version
else
  ...
fi
```

If Docker is missing, it installs Docker from Docker’s official repository using:

```Bash
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

### Why I did this

I wanted the script to avoid reinstalling Docker unnecessarily.

I also wanted it to install modern Docker packages instead of relying only on Ubuntu’s older `docker.io` package.

* * *

## 5. I Made Host Networking Changes Optional

### Original behavior

The original script changed networking automatically.

It modified files such as:

```Bash
/etc/network/interfaces
/etc/default/grub
/etc/netplan/50-cloud-init.yaml
```

It also forced interface renaming using:

```Bash
net.ifnames=0 biosdevname=0
```

and replaced names like:

```Bash
ens5 -> eth0
ens6 -> eth1
```

### Problem I faced

In my VM setup, networking was already manually configured.

I had NAT and internal networking in VirtualBox, and my interfaces did not always match the script’s assumptions.

The original script could interfere with my working network configuration.

### My modification

I added this option:

```Bash
CONFIGURE_NETWORKING="${CONFIGURE_NETWORKING:-false}"
```

By default, the script now skips host networking changes:

```Bash
info "Skipping host networking changes"
```

The legacy networking behavior only runs if I explicitly enable it:

```Bash
sudo CONFIGURE_NETWORKING=true ./agw_install_docker_compose_v2.sh
```

### Why I did this

I wanted the script to preserve my existing VM networking by default.

This is especially useful when I have already configured:

* NAT interface for internet
* internal interface for agw-to-orc8r communication
* static IP addresses
* `/etc/hosts` entries

* * *

## 6. I Added Interface Auto-Detection

### Problem I faced

The original script assumed the AGW interfaces would be:

```Bash
eth0
eth1
```

But in many Ubuntu VMs, interface names can be different, such as:

```Bash
enp0s3
enp0s8
```

This caused Magma configs to reference interfaces that did not actually exist.

### My modification

I added functions to detect the real interfaces:

```Bash
detect_default_route_iface()
detect_lan_iface()
detect_iface_ip()
detect_or_validate_interfaces()
```

The script detects:

* the NAT/default route interface
* the internal/LAN interface
* the AGW LAN IP address

### Why I did this

Magma needs correct interface names in its config files.

If Magma expects `eth1` but the VM actually uses `enp0s8`, services like MME, SPGW, or pipelined may fail.

### How someone can override detection

If auto-detection is wrong, a person can manually provide values:

```Bash
sudo AGW_NAT_IFACE=enp0s3 AGW_LAN_IFACE=enp0s8 AGW_LAN_IP=192.168.60.1 ./agw_install_docker_compose_v2.sh
```

* * *

## 7. I added magma config reconciliation

### Problem I faced

Even if the host networking was correct, Magma-generated config files could still contain old assumptions like:

```Bash
eth0
eth1
```

This could break AGW services.

### My modification

I added:

```Bash
PATCH_MAGMA_CONFIGS="${PATCH_MAGMA_CONFIGS:-true}"
```

After Ansible finishes, the script runs:

```Bash
reconcile_magma_configs_with_host_networking
```

This patches files under:

```Bash
/var/opt/magma/configs
```

### Why I did this

I wanted the final generated Magma configs to match the real VM interface names.

This makes the script more useful for VirtualBox, cloud VMs, and machines where interface names are not `eth0` and `eth1`.

### How to disable it

If someone wants to skip config patching:

```Bash
sudo PATCH_MAGMA_CONFIGS=false ./agw_install_docker_compose_v2.sh
```

* * *

## 8. I Patched Important AGW Config Files

### Files patched

The new script specifically patches:

```Bash
/var/opt/magma/configs/mme.yml
/var/opt/magma/configs/spgw.yml
/var/opt/magma/configs/pipelined.yml
```

### Why these files matter

These files contain important interface-related settings for AGW services.

For example:

```Bash
nat_iface
s11_iface_name
s1ap_iface_name
gtpu_iface_name
s1u_iface_name
sgi_management_iface
uplink_iface
```

### My modification

For `mme.yml`, I patch keys like:

```Bash
enable_nat: true
nat_iface: "<NAT interface>"
s11_iface_name: "<LAN interface>"
s1ap_iface_name: "<LAN interface>"
gtpu_iface_name: "<LAN interface>"
s1u_iface_name: "<LAN interface>"
s1ap_ipv6_enabled: false
```

For `spgw.yml`, I patch keys like:

```Bash
s11_iface_name
s1u_iface_name
sgi_management_iface
sgw_s5s8_up_iface_name
sgw_s5s8_up_iface_name_non_nat
```

For `pipelined.yml`, I patch:

```Bash
nat_iface
uplink_iface
clean_restart
```

### Why I did this

I encountered problems where AGW services could fail because generated configs were incomplete or used wrong interface names.

This patching step makes the installed AGW more consistent with the actual host networking.

* * *

## 9. I Added Protection Against Incomplete `mme.yml`

### Problem I faced

In some cases, `mme.yml` could be generated in an incomplete or minimal form.

That can cause errors such as missing keys.

### My modification

I added:

```Bash
restore_mme_if_incomplete()
```

This checks the number of lines in `mme.yml`.

If it looks too small, the script backs it up and restores the full template:

```Bash
cp "$config" "${config}.bak.$(date +%Y%m%d%H%M%S)"
cp "$template" "$config"
```

### Why I did this

I did not want the script to continue with a broken or incomplete MME config.

This helps prevent later runtime errors inside the AGW containers.

* * *

## 10. I Added Template Restoration for Missing Configs

### Problem I faced

Some config files might not exist after installation or generation.

### My modification

I added:

```Bash
restore_config_from_template_if_missing()
```

This restores missing configs from:

```Bash
$MAGMA_ROOT/lte/gateway/configs/
```

to:

```Bash
/var/opt/magma/configs/
```

### Why I did this

This makes the script more self-fixing.

If `spgw.yml` or `pipelined.yml` is missing, the script can restore it before patching it.

* * *

## 11. I Added Kernel Compatibility Checks

### Problem I faced

Magma AGW v1.8 can be sensitive to kernel versions because of OVS DKMS and related kernel modules.
It happened to me and I had rto manually install a right kernel after checking uname  -r

Using a newer kernel can break installation or cause DKMS failures.

### My modification

I added kernel detection:

```Bash
KERNEL_VERSION="$(uname -r)"
KERNEL_MAJOR="$(echo "$KERNEL_VERSION" | cut -d. -f1)"
KERNEL_MINOR="$(echo "$KERNEL_VERSION" | cut -d. -f2)"
```

Then I added a check:

```Bash
if [ "$KERNEL_MAJOR" -gt 5 ] || { [ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -gt 8 ]; }; then
  echo "ERROR: Kernel $KERNEL_VERSION may be incompatible with Magma AGW OVS DKMS."
  echo "Recommended: Ubuntu 20.04 GA kernel 5.4.x."
  ...
fi
```

### Why I did this

I wanted the script to fail early instead of breaking halfway through the install.

### How someone can override it

If someone understands the risk and still wants to continue:

```Bash
sudo ALLOW_UNSUPPORTED_KERNEL=true ./agw_install_docker_compose_v2.sh
```

* * *

## 12. I Improved Ubuntu Version Handling

### Original behavior

The original script only checked whether Ubuntu was installed by reading:

```Bash
/etc/issue
```

### My modification

The new script reads:

```Bash
/etc/os-release
```

and checks:

```Bash
ID=ubuntu
VERSION_ID
VERSION_CODENAME
```

### Why I did this

This is cleaner and more reliable than checking `/etc/issue`.

The script also warns when the Ubuntu version is not the expected one for Magma AGW v1.8:

```Bash
Magma AGW v1.8 is primarily expected on Ubuntu 20.04.
```

* * *

## 13. I Improved Ansible Installation Logic

### Original behavior

The original script simply ran:

```Bash
pip3 install ansible==5.0.1
```

### Problem I faced

Newer Ubuntu versions can restrict system-wide pip installs.

For example, Ubuntu 24.04 may require:

```Bash
--break-system-packages
```

### My modification

The new script handles different Ubuntu versions:

```Bash
if [ "$UBUNTU_VERSION" = "24.04" ]; then
  pip3 install --break-system-packages ansible==5.0.1 || apt-get install -y ansible
elif [ "$UBUNTU_VERSION" = "22.04" ]; then
  pip3 install ansible==5.0.1 || pip3 install --break-system-packages ansible==5.0.1 || apt-get install -y ansible
else
  pip3 install ansible==5.0.1 || apt-get install -y ansible
fi
```

**I tested this on my 20.04.6 version of ubuntu, it worked**

### Why I did this

I wanted the script to have a fallback instead of failing immediately when pip installation behaves differently across Ubuntu versions.

* * *

## 14. I Made Root CA Location Configurable

### Original behavior

The original script expected:

```Bash
/var/opt/magma/certs/rootCA.pem
```

### My modification

The new script still uses that as the default, but allows overriding it:

```Bash
ROOTCA="${ROOTCA:-/var/opt/magma/certs/rootCA.pem}"
```

### Why I did this

In my setup, I copied `rootCA.pem` from the Orc8r machine to the AGW machine.

The default path is still correct for my use case, but now someone else can use another path if needed:

```Bash
sudo ROOTCA=/custom/path/rootCA.pem ./agw_install_docker_compose_v2.sh
```

* * *

## 15. I Made Magma Root Path Configurable

### Original behavior

The original script always used:

```Bash
/opt/magma
```

### My modification

The new script uses:

```Bash
MAGMA_ROOT="${MAGMA_ROOT:-/opt/magma}"
```

### Why I did this

This allows someone to use a different install path if needed.

Example:

```Bash
sudo MAGMA_ROOT=/var/opt/magma ./agw_install_docker_compose_v2.sh
```

* * *

## 16. I Kept Magma Version and Git URL Configurable

### Original behavior

The original script already supported:

```Bash
MAGMA_VERSION="${MAGMA_VERSION:-v1.8}"
GIT_URL="${GIT_URL:-https://github.com/magma/magma.git}"
```

### My newer script keeps this behavior

This means I can still run:

```Bash
sudo MAGMA_VERSION=v1.8 ./agw_install_docker_compose_v2.sh
```

or use a fork:

```Bash
sudo GIT_URL=https://github.com/myname/magma.git ./agw_install_docker_compose_v2.sh
```

### Why this is useful

It makes the script easier to test with:

* official Magma
* a fork
* a specific branch
* a specific tag

* * *

## 17. I Improved Error Messages

### Original behavior

The original script used direct `echo` and `exit`.

### My modification

I added helper functions:

```Bash
die()
info()
warn()
```

### Why I did this

This makes script output easier to understand.

For example:

```Bash
die "Missing rootCA at $ROOTCA"
```

is clearer than a generic failure.

* * *

## 18. I Stopped Creating a New User Automatically

### Original behavior

The original script could create the `ubuntu` user if it did not exist:

```Bash
adduser --disabled-password --gecos "" $MAGMA_USER
adduser $MAGMA_USER sudo
```

### Problem I faced

This caused confusion because I already had a user on the VM and it crearted ubuntu as new user and I was not able to login .

### My modification

The new script requires the selected user to already exist:

```Bash
id "$MAGMA_USER" >/dev/null 2>&1 || die "User does not exist: $MAGMA_USER"
```

### Why I did this

I wanted the script to avoid unexpectedly creating users.

This is safer and clearer.

* * *

## 19. I Added the User to Docker and Sudo Groups More Cleanly

### New behavior

The new script runs:

```Bash
usermod -aG sudo "$MAGMA_USER"
usermod -aG docker "$MAGMA_USER"
```

It also creates a sudoers file:

```Bash
/etc/sudoers.d/magma-agw-$MAGMA_USER
```

### Why I did this

This is cleaner than directly appending to `/etc/sudoers`.

It is easier to review, remove, or modify later.

* * *

## 20. I Kept the Original Ansible Deployment Flow

### Original behavior

The original script generated:

```Bash
agw_hosts
```

and then ran:

```Bash
ansible-playbook
```

with either:

```Bash
--tags base
```

or:

```Bash
--tags agwc
```

### My newer script keeps this structure

For base mode:

```Bash
sudo ./agw_install_docker_compose_v2.sh base
```

For normal AGW install:

```Bash
sudo ./agw_install_docker_compose_v2.sh
```

### Why I kept it

The Ansible playbook is still the main Magma-supported installation mechanism.

I did not replace the Magma install logic completely. I only made the wrapper script safer and more compatible with my environment.

* * *

## 21. I Added a Final Summary

### New behavior

At the end, the script prints:

```Bash
AGW install completed
```

and summarizes:

```Bash
User
Docker Compose v2 used
Host networking preserved
Magma configs reconciled
NAT interface
LAN interface
LAN IP
```

### Why I added this

I wanted a clear final output showing what the script actually did.

This helps me verify whether the script detected the correct interfaces and whether config reconciliation happened.

* * *

# How I Use the New Script

## Normal usage

I run:

```Bash
sudo ./agw_install_docker_compose_v2.sh
```

This does the normal AGW Docker install while preserving existing host networking.

* * *

## If I only want base dependencies

I run:

```Bash
sudo ./agw_install_docker_compose_v2.sh base
```

* * *

## If I want to manually specify interfaces

I run:

```Bash
sudo AGW_NAT_IFACE=enp0s3 AGW_LAN_IFACE=enp0s8 AGW_LAN_IP=192.168.60.1 ./agw_install_docker_compose_v2.sh
```

* * *

## If I want legacy networking behavior

I run:

```Bash
sudo CONFIGURE_NETWORKING=true ./agw_install_docker_compose_v2.sh
```

* * *

## If I want to skip Magma config patching

I run:

```Bash
sudo PATCH_MAGMA_CONFIGS=false ./agw_install_docker_compose_v2.sh
```

* * *

## If I want to continue with an unsupported kernel

I run:

```Bash
sudo ALLOW_UNSUPPORTED_KERNEL=true ./agw_install_docker_compose_v2.sh
```

* * *

## If I want to use a custom Magma repository

I run:

```Bash
sudo GIT_URL=https://github.com/myname/magma.git ./agw_install_docker_compose_v2.sh
```

* * *

## If I want to use a custom Magma version

I run:

```Bash
sudo MAGMA_VERSION=v1.8 ./agw_install_docker_compose_v2.sh
```

* * *

* * *    
* Modified Compose v2 script:
    
    agw_install_docker_compose_v2
    [click here](./MagmaDeploy/magma-scriptv2/agw_install_docker_compose_v2.sh)

* * *
