# ── RunPod serverless extract endpoint ───────────────────────────────────────
# The endpoint is NOT managed by Terraform — the RunPod provider has two bugs:
#   1. Creates successfully (HTTP 201) but treats it as an error (expects 200)
#   2. Post-apply consistency check fails on compute_type / vcpu_count fields
#   3. Import is not supported by the provider
#
# Workflow: update runpod_template (below) to change image; the endpoint picks
# it up automatically. Endpoint ID lives in ansible/group_vars/cloud.yml.
