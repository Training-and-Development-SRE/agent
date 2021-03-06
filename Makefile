.DEFAULT_GOAL := all
.PHONY: all agent agentctl check-mod int test clean cmd/agent/agent cmd/agentctl/agentctl protos

SHELL = /usr/bin/env bash

#############
# Variables #
#############

# When the value of empty, no -mod parameter will be passed to go.
# For Go 1.13, "readonly" and "vendor" can be used here.
# In Go >=1.14, "vendor" and "mod" can be used instead.
GOMOD?=vendor
ifeq ($(strip $(GOMOD)),) # Is empty?
	MOD_FLAG=
	GOLANGCI_ARG=
else
	MOD_FLAG=-mod=$(GOMOD)
	GOLANGCI_ARG=--modules-download-mode=$(GOMOD)
endif

# Docker image info
IMAGE_PREFIX ?= grafana
IMAGE_TAG ?= $(shell ./tools/image-tag)

# Setting CROSS_BUILD=true enables cross-compiling `agent` and `agentctl` for
# different architectures. When true, docker buildx is used instead of docker,
# and seego is used for building binaries instead of go.
CROSS_BUILD ?= false

# Certain aspects of the build are done in containers for consistency.
# If you have the correct tools installed and want to speed up development,
# run make BUILD_IN_CONTAINER=false <target>, or you can set BUILD_IN_CONTAINER=true
# as an environment variable.
BUILD_IN_CONTAINER ?= true
BUILD_IMAGE_VERSION := 0.10.0
BUILD_IMAGE := $(IMAGE_PREFIX)/agent-build-image:$(BUILD_IMAGE_VERSION)

# Enables the binary to be built with optimizations (i.e., doesn't strip the image of
# symbols, etc.)
RELEASE_BUILD ?= false

# Version info for binaries
GIT_REVISION := $(shell git rev-parse --short HEAD)
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)

# When running find there's a set of directories we'll never care about; we
# define the list here to make scanning faster.
DONT_FIND := -name tools -prune -o -name vendor -prune -o -name .git -prune -o -name .cache -prune -o -name .pkg -prune -o

# Build flags
VPREFIX        := github.com/grafana/agent/pkg/build
GO_LDFLAGS     := -X $(VPREFIX).Branch=$(GIT_BRANCH) -X $(VPREFIX).Version=$(IMAGE_TAG) -X $(VPREFIX).Revision=$(GIT_REVISION) -X $(VPREFIX).BuildUser=$(shell whoami)@$(shell hostname) -X $(VPREFIX).BuildDate=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
GO_FLAGS       := -ldflags "-extldflags \"-static\" -s -w $(GO_LDFLAGS)" -tags "netgo static_build" $(MOD_FLAG)
DEBUG_GO_FLAGS := -gcflags "all=-N -l" -ldflags "-extldflags \"-static\" $(GO_LDFLAGS)" -tags "netgo static_build" $(MOD_FLAG)
DOCKER_BUILD_FLAGS = --build-arg RELEASE_BUILD=$(RELEASE_BUILD) --build-arg IMAGE_TAG=$(IMAGE_TAG)

# We need a separate set of flags for CGO, where building with -static can
# cause problems with some C libraries.
CGO_FLAGS := -ldflags "-s -w $(GO_LDFLAGS)" -tags "netgo" $(MOD_FLAG)
DEBUG_CGO_FLAGS := -gcflags "all=-N -l" -ldflags "-s -w $(GO_LDFLAGS)" -tags "netgo" $(MOD_FLAG)

# If we're not building the release, use the debug flags instead.
ifeq ($(RELEASE_BUILD),false)
GO_FLAGS = $(DEBUG_GO_FLAGS)
endif

NETGO_CHECK = @strings $@ | grep cgo_stub\\\.go >/dev/null || { \
       rm $@; \
       echo "\nYour go standard library was built without the 'netgo' build tag."; \
       echo "To fix that, run"; \
       echo "    sudo go clean -i net"; \
       echo "    sudo go install -tags netgo std"; \
       false; \
}

# Protobuf files
PROTO_DEFS := $(shell find . $(DONT_FIND) -type f -name '*.proto' -print)
PROTO_GOS := $(patsubst %.proto,%.pb.go,$(PROTO_DEFS))

# Packaging
PACKAGE_VERSION := $(patsubst v%,%,$(RELEASE_TAG))
# The number of times this version of the software was released, starting with 1 for the first release.
PACKAGE_RELEASE := 1

############
# Commands #
############

DOCKERFILE = Dockerfile

seego = docker run --rm -t -v "$(CURDIR):$(CURDIR)" -w "$(CURDIR)" -e "CGO_ENABLED=$$CGO_ENABLED" -e "GOOS=$$GOOS" -e "GOARCH=$$GOARCH" -e "GOARM=$$GOARM" rfratto/seego
docker-build = docker build $(DOCKER_BUILD_FLAGS)

ifeq ($(CROSS_BUILD),true)
DOCKERFILE = Dockerfile.buildx

docker-build = docker buildx build --push --platform linux/amd64,linux/arm64,linux/arm/v6,linux/arm/v7 $(DOCKER_BUILD_FLAGS)
endif

ifeq ($(BUILD_IN_CONTAINER),false)
seego = "/seego.sh"
endif

#############
# Protobufs #
#############

protos: $(PROTO_GOS)

# Use with care; this signals to make that the proto definitions don't need recompiling.
touch-protos:
	for proto in $(PROTO_GOS); do [ -f "./$${proto}" ] && touch "$${proto}" && echo "touched $${proto}"; done

%.pb.go: $(PROTO_DEFS)
ifeq ($(BUILD_IN_CONTAINER),true)
	@mkdir -p $(shell pwd)/.pkg
	@mkdir -p $(shell pwd)/.cache
	docker run -i \
		-v $(shell pwd)/.cache:/go/cache \
		-v $(shell pwd)/.pkg:/go/pkg \
		-v $(shell pwd):/src/agent \
		-e SRC_PATH=/src/agent \
		$(BUILD_IMAGE) $@;
else
	protoc -I .:./vendor:./$(@D) --gogoslick_out=Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types,plugins=grpc,paths=source_relative:./ ./$(patsubst %.pb.go,%.proto,$@);
endif

###################
# Primary Targets #
###################
all: protos agent agentctl
agent: cmd/agent/agent
agentctl: cmd/agentctl/agentctl

cmd/agent/agent: cmd/agent/main.go
ifeq ($(CROSS_BUILD),false)
	CGO_ENABLED=1 go build $(CGO_FLAGS) -o $@ ./$(@D)
else
	@CGO_ENABLED=1 GOOS=$(GOOS) GOARCH=$(GOARCH) GOARM=$(GOARM); $(seego) build $(CGO_FLAGS) -o $@ ./$(@D)
endif
	$(NETGO_CHECK)

cmd/agentctl/agentctl: cmd/agentctl/main.go
ifeq ($(CROSS_BUILD),false)
	CGO_ENABLED=1 go build $(CGO_FLAGS) -o $@ ./$(@D)
else
	@CGO_ENABLED=1 GOOS=$(GOOS) GOARCH=$(GOARCH) GOARM=$(GOARM); $(seego) build $(CGO_FLAGS) -o $@ ./$(@D)
endif
	$(NETGO_CHECK)

agent-image:
	$(docker-build) -t $(IMAGE_PREFIX)/agent:latest -t $(IMAGE_PREFIX)/agent:$(IMAGE_TAG) -f cmd/agent/$(DOCKERFILE) .

agentctl-image:
	$(docker-build) -t $(IMAGE_PREFIX)/agentctl:latest -t $(IMAGE_PREFIX)/agentctl:$(IMAGE_TAG) -f cmd/agentctl/$(DOCKERFILE) .

install:
	CGO_ENABLED=1 go install $(CGO_FLAGS) ./cmd/agent
	CGO_ENABLED=0 go install $(GO_FLAGS) ./cmd/agentctl

#######################
# Development targets #
#######################

lint:
	GO111MODULE=on GOGC=10 golangci-lint run -v --timeout=10m $(GOLANGCI_ARG)

# We have to run test twice: once for all packages with -race and then once more without -race
# for packages that have known race detection issues
test:
	GOGC=10 go test $(MOD_FLAG) -race -cover -coverprofile=cover.out -p=4 ./...
	GOGC=10 go test $(MOD_FLAG) -cover -coverprofile=cover-norace.out -p=4 ./pkg/integrations/node_exporter

clean:
	rm -rf cmd/agent/agent
	go clean $(MOD_FLAG) ./...

example-kubernetes:
	cd production/kubernetes/build && bash build.sh

example-dashboards:
	cd example/docker-compose/grafana/dashboards && \
		jsonnet template.jsonnet -J ../../vendor -m .

#############
# Releasing #
#############

# dist builds the agent and agentctl for all different supported platforms.
# Most of these platforms need CGO_ENABLED=1, but to simplify things we'll
# use CGO_ENABLED for all of them. We define them all as separate targets
# to allow for parallelization with make -jX.
#
# We use rfratto/seego for building these cross-platform images. seego provides
# a docker image with gcc toolchains for all of these platforms.
dist: dist-agent dist-agentctl dist-packages
	for i in dist/agent*; do zip -j -m $$i.zip $$i; done
	pushd dist && sha256sum * > SHA256SUMS && popd
.PHONY: dist

dist-agent: dist/agent-linux-amd64 dist/agent-linux-arm64 dist/agent-linux-armv6 dist/agent-linux-armv7 dist/agent-darwin-amd64 dist/agent-windows-amd64.exe
dist/agent-linux-amd64:
	@CGO_ENABLED=1 GOOS=linux GOARCH=amd64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent
dist/agent-linux-arm64:
	@CGO_ENABLED=1 GOOS=linux GOARCH=arm64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent
dist/agent-linux-armv6:
	@CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=6; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent
dist/agent-linux-armv7:
	@CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent
dist/agent-darwin-amd64:
	@CGO_ENABLED=1 GOOS=darwin GOARCH=amd64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent
dist/agent-windows-amd64.exe:
	@CGO_ENABLED=1 GOOS=windows GOARCH=amd64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist-agentctl: dist/agentctl-linux-amd64 dist/agentctl-linux-arm64 dist/agentctl-linux-armv6 dist/agentctl-linux-armv7 dist/agentctl-darwin-amd64 dist/agentctl-windows-amd64.exe
dist/agentctl-linux-amd64:
	@CGO_ENABLED=1 GOOS=linux GOARCH=amd64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl
dist/agentctl-linux-arm64:
	@CGO_ENABLED=1 GOOS=linux GOARCH=arm64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl
dist/agentctl-linux-armv6:
	@CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=6; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl
dist/agentctl-linux-armv7:
	@CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl
dist/agentctl-darwin-amd64:
	@CGO_ENABLED=1 GOOS=darwin GOARCH=amd64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl
dist/agentctl-windows-amd64.exe:
	@CGO_ENABLED=1 GOOS=windows GOARCH=amd64; $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

build-image/.uptodate: build-image/Dockerfile
	docker pull $(BUILD_IMAGE) || docker build -t $(BUILD_IMAGE) $(@D)
	touch $@

build-image/.published: build-image/.uptodate
ifneq (,$(findstring WIP,$(IMAGE_TAG)))
	@echo "Cannot push a WIP image, commit changes first"; \
	false
endif
	docker push $(IMAGE_PREFIX)/agent-build-image:$(BUILD_IMAGE_VERSION)

packaging/debian-systemd/.uptodate: $(wildcard packaging/debian-systemd/*)
	docker pull $(IMAGE_PREFIX)/debian-systemd || docker build -t $(IMAGE_PREFIX)/debian-systemd $(@D)
	touch $@

packaging/centos-systemd/.uptodate: $(wildcard packaging/centos-systemd/*)
	docker pull $(IMAGE_PREFIX)/centos-systemd || docker build -t $(IMAGE_PREFIX)/centos-systemd $(@D)
	touch $@

ifeq ($(BUILD_IN_CONTAINER), true)
dist-packages: enforce-release-tag dist-agent dist-agentctl build-image/.uptodate
	docker run --rm \
		-v  $(shell pwd):/src/agent:delegated \
		-e RELEASE_TAG=$(RELEASE_TAG) \
		-e SRC_PATH=/src/agent \
		-i $(BUILD_IMAGE) $@;
.PHONY: dist-packages
else
dist-packages:
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).amd64.rpm
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).amd64.deb
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).arm64.deb
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).arm64.rpm
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).armv7.deb
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).armv7.rpm
	make dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE).armv6.deb
.PHONY: dist-packages

ENVIRONMENT_FILE_rpm := /etc/sysconfig/grafana-agent
ENVIRONMENT_FILE_deb := /etc/default/grafana-agent

# generate_fpm(deb|rpm, package arch, agent arch, output file)
define generate_fpm =
	fpm -s dir -v $(PACKAGE_VERSION) -a $(2) \
		-n grafana-agent --iteration $(PACKAGE_RELEASE) -f \
		--log error \
		--license "Apache 2.0" \
		--vendor "Grafana Labs" \
		--url "https://github.com/grafana/agent" \
		-t $(1) \
		--after-install packaging/$(1)/control/postinst \
		--before-remove packaging/$(1)/control/prerm \
		--package $(4) \
			dist/agent-linux-$(3)=/usr/bin/grafana-agent \
			dist/agentctl-linux-$(3)=/usr/bin/grafana-agentctl \
			packaging/grafana-agent.yaml=/etc/grafana-agent.yaml \
			packaging/environment-file=$(ENVIRONMENT_FILE_$(1)) \
			packaging/$(1)/grafana-agent.service=/usr/lib/systemd/system/grafana-agent.service
endef

PACKAGE_PREFIX := dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE)
DEB_DEPS := $(wildcard packaging/deb/**/*) packaging/grafana-agent.yaml
RPM_DEPS := $(wildcard packaging/rpm/**/*) packaging/grafana-agent.yaml

# Build architectures for packaging based on the agent build:
#
# agent amd64, deb amd64, rpm x86_64
# agent arm64, deb arm64, rpm aarch64
# agent armv7, deb armhf, rpm armhfp
# agent armv6, deb armhf, (No RPM for armv6)
$(PACKAGE_PREFIX).amd64.deb: dist/agent-linux-amd64 dist/agentctl-linux-amd64 $(DEB_DEPS)
	$(call generate_fpm,deb,amd64,amd64,$@)
$(PACKAGE_PREFIX).arm64.deb: dist/agent-linux-arm64 dist/agentctl-linux-arm64 $(DEB_DEPS)
	$(call generate_fpm,deb,arm64,arm64,$@)
$(PACKAGE_PREFIX).armv7.deb: dist/agent-linux-armv7 dist/agentctl-linux-armv7 $(DEB_DEPS)
	$(call generate_fpm,deb,armhf,armv7,$@)
$(PACKAGE_PREFIX).armv6.deb: dist/agent-linux-armv6 dist/agentctl-linux-armv6 $(DEB_DEPS)
	$(call generate_fpm,deb,armhf,armv6,$@)

$(PACKAGE_PREFIX).amd64.rpm: dist/agent-linux-amd64 dist/agentctl-linux-amd64 $(RPM_DEPS)
	$(call generate_fpm,rpm,x86_64,amd64,$@)
$(PACKAGE_PREFIX).arm64.rpm: dist/agent-linux-arm64 dist/agentctl-linux-arm64 $(RPM_DEPS)
	$(call generate_fpm,rpm,aarch64,arm64,$@)
$(PACKAGE_PREFIX).armv7.rpm: dist/agent-linux-armv7 dist/agentctl-linux-armv7 $(RPM_DEPS)
	$(call generate_fpm,rpm,armhfp,armv7,$@)

endif

enforce-release-tag:
	@sh -c '[ -n "${RELEASE_TAG}" ] || (echo \$$RELEASE_TAG environment variable not set; exit 1)'

test-packages: enforce-release-tag dist-packages packaging/centos-systemd/.uptodate packaging/debian-systemd/.uptodate
	./tools/test-packages $(IMAGE_PREFIX) $(PACKAGE_VERSION) $(PACKAGE_RELEASE)
.PHONY: test-package

clean-dist:
	rm -rf dist
.PHONY: clean

publish: dist
	./tools/release
