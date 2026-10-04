# NICo Site Network Design — control-plane-3 + tray-6 + tray-7

## Scope

- **NICo site controller**: SNO OpenShift on `control-plane-3`
- **Targets**: `compute-tray-6` and `compute-tray-7` (bare-metal provisioned by NICo)
- **Goal**: Isolated provisioning and workload networks, leaving the shared fabric untouched

---

## New VLANs

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| **210** | NICo Provisioning | `172.16.10.0/24` | DHCP, PXE, DNS — tray-6/7 boot |
| **211** | NICo BMC Isolated | `172.16.11.0/24` | Isolated BMC for tray-6/7 only |
| **212** | NICo Workload | `172.16.12.0/24` | Post-provision tenant data plane |

Existing networks are **not modified**:

| Existing | Subnet | Shared by |
|----------|--------|-----------|
| OOB/Management | `172.16.0.x/24` | All BMCs, switches |
| Host Management | `172.16.2.x/24` | All 13 control-plane nodes, all 18 tray OOBs |
| North-South | `172.16.3.x/24` | All hosts data plane |
| Storage LACP | `172.16.5.x/24` | All storage traffic |
| NVLink Management | VLAN 200 | NVLink switches |

---

## IP Address Assignments

### VLAN 210 — NICo Provisioning (`172.16.10.0/24`)

| IP | Role |
|----|------|
| `172.16.10.1` | L3 gateway — SVI on sn5600-csl-01/02 |
| `172.16.10.2` | control-plane-3 subinterface (`bond-ns.210`) |
| **`172.16.10.10`** | **MetalLB VIP** — all NICo site services |
| `172.16.10.101` | DHCP reservation — tray-6 boot (MAC `e0:9d:73:87:03:70`) |
| `172.16.10.102` | DHCP reservation — tray-7 boot (MAC `e0:9d:73:86:d4:52`) |
| `172.16.10.128–254` | DHCP pool (dynamic, for iPXE stages) |

### VLAN 211 — NICo BMC Isolated (`172.16.11.0/24`)

| IP | Role |
|----|------|
| `172.16.11.1` | L3 gateway — SVI on sn2201dc-mgmt-sw-01/02 (see note below) |
| `172.16.11.2` | control-plane-3 subinterface (`bond-ns.211`) |
| `172.16.11.6` | tray-6 AMI MegaRAC BMC (static, re-assigned from `172.16.2.66`) |
| `172.16.11.7` | tray-7 AMI MegaRAC BMC (static, re-assigned from `172.16.2.67`) |
| `172.16.11.16` | tray-6 DPU BlueField OpenBMC (static) |
| `172.16.11.17` | tray-7 DPU BlueField OpenBMC (static) |
| `172.16.11.26` | tray-6 host OOB (`oob_net0`) |
| `172.16.11.27` | tray-7 host OOB (`oob_net0`) |

> **Note**: The uplink ports from `sn2201dc-mgmt-sw-01/02` to the main fabric are not documented in
> the saved LaunchPad pages. Verify these uplinks before configuring VLAN 211 routing. If the
> sn2201dc switches do not connect to the sn5600-csl fabric, an alternative is to route VLAN 211
> via the sn2201-mg switches and control-plane-3's management bond.

### VLAN 212 — NICo Workload (`172.16.12.0/24`)

| IP | Role |
|----|------|
| `172.16.12.1` | L3 gateway — SVI on sn5600-csl-01/02 |
| `172.16.12.6` | tray-6 provisioned OS address |
| `172.16.12.7` | tray-7 provisioned OS address |
| `172.16.12.0/24` | Full tenant address pool (NICo manages allocation) |

---

## DNS and Subdomains

NICo's DNS service runs at the MetalLB VIP `172.16.10.10:53` and is authoritative for the site domain. Upstream queries forward to `172.16.0.1` (LaunchPad DNS).

> Adjust `nico-site` below to match the actual SNO cluster name used at install time.

| Record | Type | Value | Notes |
|--------|------|-------|-------|
| `api.nico-site.launchpad.local` | A | `172.16.2.123` | SNO Kubernetes API (control-plane-3 Host Management IP) |
| `*.apps.nico-site.launchpad.local` | A | `172.16.2.123` | SNO Ingress / OpenShift Routes |
| `nico-api.nico-site.launchpad.local` | A | `172.16.10.10` | NICo gRPC API (MetalLB VIP) |
| `compute-tray-6.nico-site.launchpad.local` | A | `172.16.10.101` | Tray-6 during provisioning |
| `compute-tray-7.nico-site.launchpad.local` | A | `172.16.10.102` | Tray-7 during provisioning |
| `compute-tray-6.workload.nico-site.launchpad.local` | A | `172.16.12.6` | Tray-6 post-provision |
| `compute-tray-7.workload.nico-site.launchpad.local` | A | `172.16.12.7` | Tray-7 post-provision |

---

## MetalLB VIP — `172.16.10.10`

Single L2 VIP on VLAN 210, announced from `bond-ns.210` on control-plane-3. NICo Core services share this VIP:

| Service | External Port | Internal Port | Protocol |
|---------|--------------|---------------|----------|
| DHCP | 67, 68 | 67, 68 | UDP |
| DNS | 53 | 5353 | UDP + TCP |
| PXE / TFTP | 69 | 69 | UDP |
| SSH Console | 22 | 2222 | TCP |
| gRPC API | 443 | 50051 | TCP |

> **Known issues** (from metallb-loadbalancer-setup.md): DNS targetPort 53→5353 and SSH 22→2222
> require upstream kustomize patches before they work correctly. Apply those patches before testing.

---

## Switch Configuration

### sn5600-csl-01 and sn5600-csl-02 — Cumulus Linux (NVUE)

> OOB management IPs: `sn5600-csl-01` → `172.16.0.10`, `sn5600-csl-02` → `172.16.0.11`

These are the collapsed spine-leaf switches. All three nodes (SNO, tray-6, tray-7) connect here.

```bash
# Add new VLANs to the bridge
nv set bridge domain br_default vlan 210
nv set bridge domain br_default vlan 212

# Trunk VLANs 210 and 212 on control-plane-3 uplink
# csl-01: swp16s1 (ens3f0np0, MAC 8c:91:3a:c8:1b:7a)
# csl-02: swp16s1 (ens3f1np1, MAC 8c:91:3a:c8:1b:7b)
nv set interface swp16s1 bridge domain br_default vlan 210
nv set interface swp16s1 bridge domain br_default vlan 212

# Access VLAN 210 on tray-6 provisioning uplink
# csl-01: swp3s1 (DPU B3420 p0, MAC e0:9d:73:87:03:70)
# csl-02: swp3s1 (DPU B3420 p1, MAC e0:9d:73:87:03:71)
nv set interface swp3s1 bridge domain br_default access 210

# Access VLAN 210 on tray-7 provisioning uplink
# csl-01: swp4s0 (DPU B3420 p0, MAC e0:9d:73:86:d4:52)
# csl-02: swp4s0 (DPU B3420 p1, MAC e0:9d:73:86:d4:53)
nv set interface swp4s0 bridge domain br_default access 210

# L3 SVIs (configure on both csl-01 and csl-02 with MLAG/VRR for HA)
nv set interface vlan210 ip address 172.16.10.1/24
nv set interface vlan212 ip address 172.16.12.1/24

nv config apply
```

> **After provisioning**: Move swp3s1 and swp4s0 from VLAN 210 to VLAN 212 to put the
> provisioned OS on the workload network. NICo's workflow should automate this transition.

### sn2201dc-mgmt-sw-01 — Cumulus Linux (NVUE)

> OOB management IP: `172.16.0.14`

Carries tray-6 and tray-7 AMI MegaRAC BMC ports.

```bash
# Add VLAN 211 and isolate tray-6 + tray-7 BMC ports
nv set bridge domain br_default vlan 211

# swp34 → tray-6 BMC (MAC 18:3d:2d:9b:b3:f4)
nv set interface swp34 bridge domain br_default access 211

# swp35 → tray-7 BMC (MAC 18:3d:2d:9b:b4:12)
nv set interface swp35 bridge domain br_default access 211

# SVI (if this switch does L3; otherwise configure on upstream switch)
nv set interface vlan211 ip address 172.16.11.1/24

nv config apply
```

### sn2201dc-mgmt-sw-02 — Cumulus Linux (NVUE)

> OOB management IP: `172.16.0.15`

Carries tray-6 and tray-7 DPU BMC, DPU host OOB, and host OOB ports.

```bash
nv set bridge domain br_default vlan 211

# swp34 → tray-6 DPU BMC (MAC e0:9d:73:87:03:85) + DPU host OOB (MAC e0:9d:73:87:03:84)
nv set interface swp34 bridge domain br_default access 211

# swp35 → tray-7 DPU BMC (MAC e0:9d:73:86:d4:67) + DPU host OOB (MAC e0:9d:73:86:d4:66)
nv set interface swp35 bridge domain br_default access 211

# swp6 → tray-6 host OOB bond (MAC c4:ef:bb:1b:09:0c)
nv set interface swp6 bridge domain br_default access 211

# swp7 → tray-7 host OOB bond (MAC c4:ef:bb:1b:09:08)
nv set interface swp7 bridge domain br_default access 211

nv config apply
```

> **Action required**: Before applying VLAN 211 on these switches, identify the uplink ports from
> sn2201dc-mgmt-sw-01/02 to the fabric and add VLAN 211 to those trunks. Also reconfigure the
> BMC IPs on both trays from their current `172.16.2.x` addresses to the new `172.16.11.x` addresses
> via the current BMC web UI before moving the switch ports.

---

## SNO (control-plane-3) — Network Interfaces

The north-south bond (`bond-ns`) is the LACP bond of `ens3f0np0` + `ens3f1np1`, already carrying `172.16.3.x` traffic. Add tagged subinterfaces for the new VLANs.

For OpenShift/SNO, configure via NMState (apply as a `MachineConfig` or at install time via the `install-config.yaml` network section):

```yaml
# NMState for control-plane-3
interfaces:
  - name: bond-ns.210
    type: vlan
    state: up
    vlan:
      base-iface: bond-ns
      id: 210
    ipv4:
      enabled: true
      address:
        - ip: 172.16.10.2
          prefix-length: 24
      dhcp: false

  - name: bond-ns.211
    type: vlan
    state: up
    vlan:
      base-iface: bond-ns
      id: 211
    ipv4:
      enabled: true
      address:
        - ip: 172.16.11.2
          prefix-length: 24
      dhcp: false

  - name: bond-ns.212
    type: vlan
    state: up
    vlan:
      base-iface: bond-ns
      id: 212
    ipv4:
      enabled: true
      address:
        - ip: 172.16.12.2
          prefix-length: 24
      dhcp: false
```

---

## MetalLB IPAddressPool

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nico-site-vip
  namespace: metallb-system
spec:
  addresses:
    - 172.16.10.10/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nico-site-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - nico-site-vip
  interfaces:
    - bond-ns.210
```

---

## Topology Diagram

```
                        ┌──────────────────────────────────────────┐
                        │   sn5600-csl-01 / sn5600-csl-02         │
                        │   (collapsed spine-leaf, Cumulus Linux)  │
                        │                                          │
                        │  swp16s1 ── control-plane-3              │
                        │            trunk: existing + VLAN 210,212│
                        │                                          │
                        │  swp3s1  ── compute-tray-6 DPU p0/p1    │
                        │            access: VLAN 210 (→212 later) │
                        │                                          │
                        │  swp4s0  ── compute-tray-7 DPU p0/p1    │
                        │            access: VLAN 210 (→212 later) │
                        │                                          │
                        │  SVI vlan210: 172.16.10.1/24            │
                        │  SVI vlan212: 172.16.12.1/24            │
                        └──────────────────────────────────────────┘

   ┌────────────────────────────────────┐
   │  control-plane-3 (SNO OpenShift)   │
   │                                    │
   │  bond-ns       → 172.16.2.123     │  (Host Management — actual node IP)
   │  bond-ns.210   → 172.16.10.2/24   │  NICo provisioning
   │  bond-ns.211   → 172.16.11.2/24   │  BMC management
   │  bond-ns.212   → 172.16.12.2/24   │  workload
   │                                    │
   │  MetalLB L2 VIP: 172.16.10.10     │
   │  ├─ DHCP     :67/68               │
   │  ├─ DNS      :53 → :5353          │
   │  ├─ PXE      :69                  │
   │  ├─ SSH      :22 → :2222          │
   │  └─ gRPC API :443                 │
   └────────────────────────────────────┘

   ┌─────────────────────────┐    ┌─────────────────────────┐
   │  compute-tray-6          │    │  compute-tray-7          │
   │                         │    │                         │
   │  DPU B3420 p0           │    │  DPU B3420 p0           │
   │  MAC e0:9d:73:87:03:70  │    │  MAC e0:9d:73:86:d4:52  │
   │  VLAN 210               │    │  VLAN 210               │
   │  DHCP → 172.16.10.101   │    │  DHCP → 172.16.10.102   │
   └─────────────────────────┘    └─────────────────────────┘

                        ┌──────────────────────────────────────────┐
                        │   sn2201dc-mgmt-sw-01                    │
                        │   swp34 → tray-6 BMC  — VLAN 211        │
                        │   swp35 → tray-7 BMC  — VLAN 211        │
                        ├──────────────────────────────────────────┤
                        │   sn2201dc-mgmt-sw-02                    │
                        │   swp34 → tray-6 DPU BMC + OOB VLAN 211 │
                        │   swp35 → tray-7 DPU BMC + OOB VLAN 211 │
                        │   swp6  → tray-6 host OOB  — VLAN 211   │
                        │   swp7  → tray-7 host OOB  — VLAN 211   │
                        │   SVI vlan211: 172.16.11.1/24            │
                        └──────────────────────────────────────────┘
```

---

## Switch Change Best Practices (Cumulus Linux / NVUE)

### Before every change

```bash
# 1. Open a BMC console session to the switch as a safety net
#    (so you retain access if SSH drops)
ssh admin@<switch-oob-ip>

# 2. Checkpoint the current config
nv config save
nv config checkpoint
```

### Apply with auto-rollback

Always use `--timeout` so the switch reverts automatically if you lose connectivity:

```bash
nv config apply --timeout 120
```

If the change looks good and SSH/connectivity is still alive, confirm to keep it:

```bash
nv config apply confirm
```

If you do not confirm within the timeout, Cumulus reverts automatically — no manual action needed.

### Manual rollback (if you still have access)

```bash
# List available checkpoints
nv config history

# Revert to a specific checkpoint
nv config revert <checkpoint-id>
```

### Persist after confirming

```bash
# Write confirmed config to disk so it survives a reboot
nv config save
```

### Summary: safe change sequence

| Step | Command |
|------|---------|
| 1. Open BMC console | (before SSH changes) |
| 2. Checkpoint | `nv config save && nv config checkpoint` |
| 3. Stage changes | `nv set ...` |
| 4. Apply with timer | `nv config apply --timeout 120` |
| 5. Verify | ping, SSH, check MACs |
| 6. Confirm | `nv config apply confirm` |
| 7. Persist | `nv config save` |

---

## Action Checklist

### Before touching switches

- [ ] Identify uplink ports from `sn2201dc-mgmt-sw-01/02` to the fabric (not documented in LaunchPad pages)
- [ ] Record current BMC IPs for tray-6 and tray-7 from `172.16.2.x` range
- [ ] Reconfigure tray-6/7 BMC IPs to `172.16.11.x` via the current BMC web UI **before** moving switch ports

### Switch changes

- [ ] Add VLAN 210, 212 + SVIs on `sn5600-csl-01`
- [ ] Add VLAN 210, 212 + SVIs on `sn5600-csl-02`
- [ ] Trunk VLAN 210, 212 on swp16s1 (both CSL switches)
- [ ] Access VLAN 210 on swp3s1 (tray-6 uplink on both CSL switches)
- [ ] Access VLAN 210 on swp4s0 (tray-7 uplink on both CSL switches)
- [ ] Add VLAN 211 on `sn2201dc-mgmt-sw-01` swp34, swp35
- [ ] Add VLAN 211 on `sn2201dc-mgmt-sw-02` swp34, swp35, swp6, swp7
- [ ] Trunk VLAN 211 on sn2201dc uplink ports toward fabric

### SNO / OpenShift

- [ ] Apply NMState config for bond-ns.210, .211, .212 on control-plane-3
- [ ] Install MetalLB operator via OLM
- [ ] Apply `IPAddressPool` + `L2Advertisement` for `172.16.10.10` on `bond-ns.210`
- [ ] Apply upstream kustomize patches (DNS targetPort 5353, SSH targetPort 2222)
- [ ] Deploy NICo Core chart (`nico-system` namespace) with `externalService` enabled

### NICo configuration

- [ ] Register site with NICo REST cloud (site agent)
- [ ] Configure DHCP reservations for tray-6 (MAC `e0:9d:73:87:03:70` → `172.16.10.101`)
- [ ] Configure DHCP reservations for tray-7 (MAC `e0:9d:73:86:d4:52` → `172.16.10.102`)
- [ ] Set BMC credentials for tray-6 (`172.16.11.6`, `172.16.11.16`) and tray-7 (`172.16.11.7`, `172.16.11.17`)
- [ ] Trigger provisioning workflow for tray-6 and tray-7
- [ ] After provisioning: move swp3s1/swp4s0 from VLAN 210 to VLAN 212 (workload network)
