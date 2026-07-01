VENV      := fsenv
PYTHON    := $(VENV)/bin/python3
APP_IMAGE ?= faceswap-app
APP_PORT  ?= 7860
WORKSPACE ?= alice-bob-001
ANSIBLE   := cd ansible && ansible-playbook

.PHONY: app app-build install-app \
        cloud-up cloud-train cloud-pull cloud-preflight cloud-tensorboard cloud-down \
        runpod-up runpod-down \
        venv extract train convert gui \
        sl-submit sl-serve \
        lint test clean help

# ── [1] App ──────────────────────────────────────────────────────────────────
# Gradio UI: upload videos → extract faces on RunPod → preview results.
#
#   make app

# Gradio UI: upload videos → extract faces on RunPod → preview results.
#
#   cp app/.env.example app/.env   # fill in RUNPOD_API_KEY and R2 credentials
#   make app

## app         — build Docker image and start the Gradio extract UI
app: app/.env app-build
	docker run --rm -p $(APP_PORT):7860 --env-file app/.env $(APP_IMAGE)

## app-build   — build the Gradio app Docker image
app-build:
	docker build -t $(APP_IMAGE) ./app

install-app: app-build

app/.env:
	@echo "app/.env not found — copy the template and fill in your credentials:"
	@echo "  cp app/.env.example app/.env"
	@exit 1

# ── [3] Cloud up ─────────────────────────────────────────────────────────────
# Provision a VastAI GPU instance and prepare it for training.
#
#   make cloud-up

## cloud-up    — provision VastAI instance, install faceswap + R2 sync cron
cloud-up:
	$(ANSIBLE) playbooks/terraform-manage-instance.yml
	$(ANSIBLE) playbooks/cloud-install-faceswap.yml
	$(ANSIBLE) playbooks/cloud-install-sync-cron.yml

# ── [4] Cloud train ──────────────────────────────────────────────────────────
# After curating face images in R2, sync them to the instance and train.
#
#   make cloud-train WORKSPACE=alice-bob-001

## cloud-train — pull faces from R2 + preflight checks + start training
cloud-train:
	$(ANSIBLE) playbooks/cloud-pull-train-faces.yml -e fs_workspace_name=$(WORKSPACE)
	$(ANSIBLE) playbooks/cloud-preflight.yml
	$(ANSIBLE) playbooks/cloud-start-training.yml

## cloud-pull  — sync approved face inputs from R2 → VastAI (WORKSPACE=<name>)
cloud-pull:
	$(ANSIBLE) playbooks/cloud-pull-train-faces.yml -e fs_workspace_name=$(WORKSPACE)

## cloud-preflight — run pre-training checks: GPU, disk space, face counts
cloud-preflight:
	$(ANSIBLE) playbooks/cloud-preflight.yml

## cloud-tensorboard — start TensorBoard on the VastAI instance
cloud-tensorboard:
	$(ANSIBLE) playbooks/cloud-start-tensorboard.yml

# ── [5] Cloud down ───────────────────────────────────────────────────────────
# Destroy the VastAI instance to stop billing.
#
#   make cloud-down

## cloud-down  — destroy the VastAI instance
cloud-down:
	$(ANSIBLE) playbooks/terraform-manage-instance.yml -e destroy=true

# ── RunPod serverless endpoint ────────────────────────────────────────────────

## runpod-up   — provision RunPod serverless endpoint for face extraction
runpod-up:
	$(ANSIBLE) playbooks/terraform-manage-instance.yml -e enable_runpod=true -e enable_vast=false

## runpod-down — destroy RunPod serverless endpoint
runpod-down:
	$(ANSIBLE) playbooks/terraform-manage-instance.yml -e enable_runpod=true -e enable_vast=false -e destroy=true

# ── Dev ──────────────────────────────────────────────────────────────────────

## venv        — create virtualenv with python3.13
venv:
	python3.13 -m venv $(VENV)

## extract     — run faceswap extract locally (ARGS="...")
extract:
	$(PYTHON) faceswap.py extract $(ARGS)

## train       — run faceswap train locally (ARGS="...")
train:
	$(PYTHON) faceswap.py train $(ARGS)

## convert     — run faceswap convert locally (ARGS="...")
convert:
	$(PYTHON) faceswap.py convert $(ARGS)

## gui         — open the faceswap GUI
gui:
	$(PYTHON) faceswap.py gui

## sl-submit   — submit a serverless extract job (ARGS="--input video.mp4 ...")
sl-submit:
	$(PYTHON) scripts/cloud/serverless_extract.py submit $(ARGS)

## sl-serve    — start the RunPod worker loop locally for testing
sl-serve:
	$(PYTHON) scripts/cloud/serverless_extract.py serve

## lint        — lint with flake8
lint:
	$(VENV)/bin/flake8 app/ scripts/ lib/ plugins/

## test        — run test suite
test:
	$(VENV)/bin/pytest tests/ $(ARGS)

## clean       — remove compiled Python files
clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.pyc" -delete 2>/dev/null || true

## help        — show this help
help:
	@echo "Workflow:"
	@echo "  [1] make app          — run Gradio extract UI (set R2/RunPod creds in app/.env)"
	@echo "  [2] make cloud-up     — provision VastAI + install faceswap"
	@echo "  [3] make cloud-train  — sync faces from R2 + train  (WORKSPACE=<name>)"
	@echo "  [4] make cloud-down   — destroy VastAI instance"
	@echo ""
	@echo "All targets:"
	@grep -E '^## ' Makefile | sed 's/^## /  /'
