.PHONY: setup test build manifests status destroy

MINIKUBE_PROFILE ?= devops-assignment
HELM_RELEASE ?= devops-assignment
IMAGE_REPOSITORY ?= ghcr.io/kiroalbatrosa/task
IMAGE_TAG ?= latest
LOCAL_IMAGE ?= devops-assignment-app:local
MINIKUBE := minikube
KUBECTL := kubectl
HELM := helm
HELM_CHART := helm/devops-assignment

setup:
	sudo env MINIKUBE_PROFILE=$(MINIKUBE_PROFILE) HELM_RELEASE=$(HELM_RELEASE) IMAGE_REPOSITORY=$(IMAGE_REPOSITORY) IMAGE_TAG=$(IMAGE_TAG) ./scripts/setup.sh

test:
	npm --prefix app ci --ignore-scripts
	npm --prefix app test
	npm --prefix app run build

build:
	docker build --tag $(LOCAL_IMAGE) app

manifests:
	@$(HELM) template $(HELM_RELEASE) $(HELM_CHART) --namespace default

status:
	$(KUBECTL) --context $(MINIKUBE_PROFILE) get pods,services --all-namespaces -l app.kubernetes.io/part-of=devops-home-assignment

destroy:
	$(MINIKUBE) delete --profile $(MINIKUBE_PROFILE)
