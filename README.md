# OCI One-Click GenAI Stack — v15j (fixed)
- Uses `filebase64("${path.module}/cloudinit.sh")` for `user_data` (no templating, no accidental ${...} interpolation).
- Provider v7.x–correct networking:
  - `route_rules { ... }` on route table
  - `egress_security_rules { ... }` + dynamic `ingress_security_rules` on security list
- CSV ports input (`open_tcp_ports_csv`) parsed in locals.
- trimspace fixes, multi-line blocks, resource precondition for `project_compartment_ocid`.
- OL9-safe cloud-init: venv install, OCI CLI to `~/bin/oci`, seeds `/opt/genai`, opens ports 22/8888/8501/1521, Oracle 23ai via Podman, logs to `/var/log/genai_setup.log`, idempotent marker.

v15n: add 'curl' to base packages and extra log banners.


v15o: switched to Oracle Linux 8 image, enabled ol8_addons, embedded and executed init-genailabs.sh.


v15p: stronger OL8 provisioning (enable ol8_addons first; ensure curl & dnf-plugins-core before bulk install).


v15q: add retry() around dnf/curl/podman and print a final COMPLETE banner.


v15r: run cloud-init in non-fatal mode (no -e) so provisioning continues even if a step fails; keep retry().


v15t: split DB to genai-23ai.service; added /etc/profile.d/genai-path.sh.


v15u: ensure both services created by cloud-init; add dnf makecache; keep OL8 and DB split.


v15v: Bake Python 3.9 on OL8 and build venv with python3.9 (JupyterLab 4.x compatible).
