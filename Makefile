IMAGE   ?= rustcfml:local
VERSION ?= $(shell sed -nE 's/^ARG RUSTCFML_VERSION=(v[0-9.]+).*/\1/p' Dockerfile | head -1)

.PHONY: build build-all run smoke test

build:            ## native arch, loaded into the local docker
	docker build --build-arg RUSTCFML_VERSION=$(VERSION) -t $(IMAGE) .

build-all:        ## both arches (no load; proves the multi-platform build)
	docker buildx build --platform linux/amd64,linux/arm64 --build-arg RUSTCFML_VERSION=$(VERSION) -t $(IMAGE) .

run: build        ## serve examples/hello on http://localhost:8500
	docker run --rm -p 8500:8500 -v "$(PWD)/examples/hello/webroot:/app" $(IMAGE)

smoke: build      ## version, extension listing, one request
	docker run --rm $(IMAGE) --version
	docker run --rm $(IMAGE) ext list
	./tests/smoke.sh $(IMAGE)

test: smoke
