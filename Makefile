IMAGE_NAME ?= localstack/localstack
IMAGE_TAG ?= $(shell cat VERSION)
VENV_BIN ?= python3 -m venv
VENV_DIR ?= .venv
PIP_CMD ?= pip3
TEST_PATH ?= .
TEST_EXEC ?= python -m
PYTEST_LOGLEVEL ?= warning
DISABLE_BOTO_RETRIES ?= 1
MAIN_CONTAINER_NAME ?= localstack-main

MAJOR_VERSION = $(shell echo ${IMAGE_TAG} | cut -d '.' -f1)
MINOR_VERSION = $(shell echo ${IMAGE_TAG} | cut -d '.' -f2)
PATCH_VERSION = $(shell echo ${IMAGE_TAG} | cut -d '.' -f3)

ifeq ($(OS), Windows_NT)
	VENV_ACTIVATE = $(VENV_DIR)/Scripts/activate
else
	VENV_ACTIVATE = $(VENV_DIR)/bin/activate
endif

VENV_RUN = . $(VENV_ACTIVATE)

usage:                    ## Show this help
	@grep -Fh "##" $(MAKEFILE_LIST) | grep -Fv fgrep | sed -e 's/:.*##\s*/##/g' | awk -F'##' '{ printf "%-25s %s\n", $$1, $$2 }'

$(VENV_ACTIVATE): pyproject.toml
	test -d $(VENV_DIR) || $(VENV_BIN) $(VENV_DIR)
	$(VENV_RUN); $(PIP_CMD) install --upgrade pip setuptools wheel plux
	touch $(VENV_ACTIVATE)

venv: $(VENV_ACTIVATE)    ## Create a new (empty) virtual environment

freeze:                   ## Run pip freeze -l in the virtual environment
	@$(VENV_RUN); pip freeze -l

upgrade-pinned-dependencies: venv
	$(VENV_RUN); $(PIP_CMD) install --upgrade pip-tools pre-commit
	$(VENV_RUN); pip-compile --strip-extras --upgrade --strip-extras -o requirements-basic.txt pyproject.toml
	$(VENV_RUN); pip-compile --strip-extras --upgrade --extra runtime -o requirements-runtime.txt pyproject.toml
	$(VENV_RUN); pip-compile --strip-extras --upgrade --extra test -o requirements-test.txt pyproject.toml
	$(VENV_RUN); pip-compile --strip-extras --upgrade --extra dev -o requirements-dev.txt pyproject.toml
	$(VENV_RUN); pip-compile --strip-extras --upgrade --extra typehint -o requirements-typehint.txt pyproject.toml
	$(VENV_RUN); pip-compile --strip-extras --upgrade --extra base-runtime -o requirements-base-runtime.txt pyproject.toml
	$(VENV_RUN); pre-commit autoupdate

install-basic: venv       ## Install basic dependencies for CLI usage into venv
	$(VENV_RUN); $(PIP_CMD) install -r requirements-basic.txt
	$(VENV_RUN); $(PIP_CMD) install $(PIP_OPTS) -e .

install-runtime: venv     ## Install dependencies for the localstack runtime into venv
	$(VENV_RUN); $(PIP_CMD) install -r requirements-runtime.txt
	$(VENV_RUN); $(PIP_CMD) install $(PIP_OPTS) -e ".[runtime]"

install-test: venv        ## Install requirements to run tests into venv
	$(VENV_RUN); $(PIP_CMD) install -r requirements-test.txt
	$(VENV_RUN); $(PIP_CMD) install $(PIP_OPTS) -e ".[test]"

install-dev: venv         ## Install developer requirements into venv
	$(VENV_RUN); $(PIP_CMD) install -r requirements-dev.txt
	$(VENV_RUN); $(PIP_CMD) install $(PIP_OPTS) -e ".[dev]"

install-dev-types: venv   ## Install developer requirements incl. type hints into venv
	$(VENV_RUN); $(PIP_CMD) install -r requirements-typehint.txt
	$(VENV_RUN); $(PIP_CMD) install $(PIP_OPTS) -e ".[typehint]"

install-s3: venv     ## Install dependencies for the localstack runtime for s3-only into venv
	$(VENV_RUN); $(PIP_CMD) install -r requirements-base-runtime.txt
	$(VENV_RUN); $(PIP_CMD) install $(PIP_OPTS) -e ".[base-runtime]"

install: install-dev entrypoints  ## Install full dependencies into venv

entrypoints:              ## Run plux to build entry points
	$(VENV_RUN); python -m plux entrypoints
	@# make sure that the entrypoints were correctly created and are non-empty
	@test -s localstack_core.egg-info/entry_points.txt || (echo "Entrypoints were not correctly created! Aborting!" && exit 1)

dist: entrypoints        ## Build source and built (wheel) distributions of the current version
	$(VENV_RUN); pip install --upgrade twine; python -m build

publish: clean-dist dist  ## Publish the library to the central PyPi repository
	# make sure the dist archive contains a non-empty entry_points.txt file before uploading
	tar --wildcards --to-stdout -xf dist/localstack?core*.tar.gz "localstack?core*/localstack_core.egg-info/entry_points.txt" | grep . > /dev/null 2>&1 || (echo "Refusing upload, localstack-core dist does not contain entrypoints." && exit 1)
	$(VENV_RUN); twine upload dist/*

coveralls:         		  ## Publish coveralls metrics
	$(VENV_RUN); coveralls

start:             		  ## Manually start the local infrastructure for testing
	($(VENV_RUN); exec bin/localstack start --host)

TAGS ?= $(IMAGE_NAME)
docker-save-image: 		  ## Export the built Docker image
	docker save -o target/localstack-docker-image-$(PLATFORM).tar $(TAGS)

# By default we export the community image
TAG ?= $(IMAGE_NAME)
# By default we load the result to the docker daemon
DOCKER_BUILD_FLAGS ?= "--load"
DOCKERFILE ?= "./Dockerfile"
docker-build: 			  ## Build Docker image
	# start build
	# --add-host: Fix for Centos host OS
	# --build-arg BUILDKIT_INLINE_CACHE=1: Instruct buildkit to inline the caching information into the image
	# --cache-from: Use the inlined caching information when building the image
	DOCKER_BUILDKIT=1 docker buildx build --pull --progress=plain \
		--cache-from $(TAG) --build-arg BUILDKIT_INLINE_CACHE=1 \
		--build-arg LOCALSTACK_PRE_RELEASE=$(shell cat VERSION | grep -v '.dev' >> /dev/null && echo "0" || echo "1") \
		--build-arg LOCALSTACK_BUILD_GIT_HASH=$(shell git rev-parse --short HEAD) \
		--build-arg=LOCALSTACK_BUILD_DATE=$(shell date -u +"%Y-%m-%d") \
		--build-arg=LOCALSTACK_BUILD_VERSION=$(IMAGE_TAG) \
		--add-host="localhost.localdomain:127.0.0.1" \
		-t $(TAG) $(DOCKER_BUILD_FLAGS) . -f $(DOCKERFILE)

docker-build-multiarch:   ## Build the Multi-Arch Full Docker Image
	# Make sure to prepare your environment for cross-platform docker builds! (see doc/developer_guides/README.md)
	# Multi-Platform builds cannot be loaded to the docker daemon from buildx, so we can't add "--load".
	make DOCKER_BUILD_FLAGS="--platform linux/amd64,linux/arm64" docker-build

SOURCE_IMAGE_NAME ?= $(IMAGE_NAME)
TARGET_IMAGE_NAME ?= $(IMAGE_NAME)
docker-push-master: 	  ## Push a single platform-specific Docker image to registry IF we are currently on the master branch
	(CURRENT_BRANCH=`(git rev-parse --abbrev-ref HEAD | grep '^master$$' || ((git branch -a | grep 'HEAD detached at [0-9a-zA-Z]*)') && git branch -a)) | grep '^[* ]*master$$' | sed 's/[* ]//g' || true`; \
		test "$$CURRENT_BRANCH" != 'master' && echo "Not on master branch.") || \
	((test "$$DOCKER_USERNAME" = '' || test "$$DOCKER_PASSWORD" = '' ) && \
		echo "Skipping docker push as no credentials are provided.") || \
	(REMOTE_ORIGIN="`git remote -v | grep '/localstack' | grep origin | grep push | awk '{print $$2}'`"; \
		test "$$REMOTE_ORIGIN" != 'https://github.com/localstack/localstack.git' && \
		test "$$REMOTE_ORIGIN" != 'git@github.com:localstack/localstack.git' && \
		echo "This is a fork and not the main repo.") || \
	( \
		docker info | grep Username || docker login -u $$DOCKER_USERNAME -p $$DOCKER_PASSWORD; \
			docker tag $(SOURCE_IMAGE_NAME):latest $(TARGET_IMAGE_NAME):latest-$(PLATFORM) && \
		((! (git diff HEAD^ VERSION | tail -n 1 | grep -v '.dev') && \
			echo "Only pushing tag 'latest' as version has not changed.") || \
			(docker tag $(TARGET_IMAGE_NAME):latest-$(PLATFORM) $(TARGET_IMAGE_NAME):stable-$(PLATFORM) && \
				docker tag $(TARGET_IMAGE_NAME):latest-$(PLATFORM) $(TARGET_IMAGE_NAME):$(IMAGE_TAG)-$(PLATFORM) && \
				docker tag $(TARGET_IMAGE_NAME):latest-$(PLATFORM) $(TARGET_IMAGE_NAME):$(MAJOR_VERSION)-$(PLATFORM) && \
				docker tag $(TARGET_IMAGE_NAME):latest-$(PLATFORM) $(TARGET_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION)-$(PLATFORM) && \
				docker tag $(TARGET_IMAGE_NAME):latest-$(PLATFORM) $(TARGET_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-$(PLATFORM) && \
				docker push $(TARGET_IMAGE_NAME):stable-$(PLATFORM) && \
				docker push $(TARGET_IMAGE_NAME):$(IMAGE_TAG)-$(PLATFORM) && \
				docker push $(TARGET_IMAGE_NAME):$(MAJOR_VERSION)-$(PLATFORM) && \
				docker push $(TARGET_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION)-$(PLATFORM) && \
				docker push $(TARGET_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-$(PLATFORM) \
				)) && \
				  docker push $(TARGET_IMAGE_NAME):latest-$(PLATFORM) \
	)

MANIFEST_IMAGE_NAME ?= $(IMAGE_NAME)
docker-create-push-manifests:	## Create and push manifests for a docker image (default: community)
	(CURRENT_BRANCH=`(git rev-parse --abbrev-ref HEAD | grep '^master$$' || ((git branch -a | grep 'HEAD detached at [0-9a-zA-Z]*)') && git branch -a)) | grep '^[* ]*master$$' | sed 's/[* ]//g' || true`; \
		test "$$CURRENT_BRANCH" != 'master' && echo "Not on master branch.") || \
	((test "$$DOCKER_USERNAME" = '' || test "$$DOCKER_PASSWORD" = '' ) && \
		echo "Skipping docker manifest push as no credentials are provided.") || \
	(REMOTE_ORIGIN="`git remote -v | grep '/localstack' | grep origin | grep push | awk '{print $$2}'`"; \
		test "$$REMOTE_ORIGIN" != 'https://github.com/localstack/localstack.git' && \
		test "$$REMOTE_ORIGIN" != 'git@github.com:localstack/localstack.git' && \
		echo "This is a fork and not the main repo.") || \
	( \
		docker info | grep Username || docker login -u $$DOCKER_USERNAME -p $$DOCKER_PASSWORD; \
			docker manifest create $(MANIFEST_IMAGE_NAME):latest --amend $(MANIFEST_IMAGE_NAME):latest-amd64 --amend $(MANIFEST_IMAGE_NAME):latest-arm64 && \
		((! (git diff HEAD^ VERSION | tail -n 1 | grep -v '.dev') && \
				echo "Only pushing tag 'latest' as version has not changed.") || \
			(docker manifest create $(MANIFEST_IMAGE_NAME):$(IMAGE_TAG) \
			--amend $(MANIFEST_IMAGE_NAME):$(IMAGE_TAG)-amd64 \
			--amend $(MANIFEST_IMAGE_NAME):$(IMAGE_TAG)-arm64 && \
			docker manifest create $(MANIFEST_IMAGE_NAME):stable \
			--amend $(MANIFEST_IMAGE_NAME):stable-amd64 \
			--amend $(MANIFEST_IMAGE_NAME):stable-arm64 && \
			docker manifest create $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION) \
			--amend $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION)-amd64 \
			--amend $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION)-arm64 && \
			docker manifest create $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION) \
			--amend $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION)-amd64 \
			--amend $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION)-arm64 && \
			docker manifest create $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION) \
			--amend $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-amd64 \
			--amend $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-arm64 && \
				docker manifest push $(MANIFEST_IMAGE_NAME):stable && \
				docker manifest push $(MANIFEST_IMAGE_NAME):$(IMAGE_TAG) && \
				docker manifest push $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION) && \
				docker manifest push $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION) && \
				docker manifest push $(MANIFEST_IMAGE_NAME):$(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION))) && \
		docker manifest push $(MANIFEST_IMAGE_NAME):latest \
	)

docker-run-tests:		  ## Initializes the test environment and runs the tests in a docker container
	docker run -e LOCALSTACK_INTERNAL_TEST_COLLECT_METRIC=1 --entrypoint= -v `pwd`/requirements-test.txt:/opt/code/localstack/requirements-test.txt -v `pwd`/tests/:/opt/code/localstack/tests/ -v `pwd`/target/:/opt/code/localstack/target/ -v /var/run/docker.sock:/var/run/docker.sock -v /tmp/localstack:/var/lib/localstack \
		$(IMAGE_NAME) \
	    bash -c "make install-test && DEBUG=$(DEBUG) PYTEST_LOGLEVEL=$(PYTEST_LOGLEVEL) PYTEST_ARGS='$(PYTEST_ARGS)' COVERAGE_FILE='$(COVERAGE_FILE)' TEST_PATH='$(TEST_PATH)' LAMBDA_IGNORE_ARCHITECTURE=1 LAMBDA_INIT_POST_INVOKE_WAIT_MS=50 TINYBIRD_PYTEST_ARGS='$(TINYBIRD_PYTEST_ARGS)' TINYBIRD_DATASOURCE='$(TINYBIRD_DATASOURCE)' TINYBIRD_TOKEN='$(TINYBIRD_TOKEN)' TINYBIRD_URL='$(TINYBIRD_URL)' CI_COMMIT_BRANCH='$(CI_COMMIT_BRANCH)' CI_COMMIT_SHA='$(CI_COMMIT_SHA)' CI_JOB_URL='$(CI_JOB_URL)' CI_JOB_NAME='$(CI_JOB_NAME)' CI_JOB_ID='$(CI_JOB_ID)' CI='$(CI)' TEST_AWS_REGION_NAME='${TEST_AWS_REGION_NAME}' TEST_AWS_ACCESS_KEY_ID='${TEST_AWS_ACCESS_KEY_ID}' TEST_AWS_ACCOUNT_ID='${TEST_AWS_ACCOUNT_ID}' make test-coverage"

docker-run-tests-s3-only:		  ## Initializes the test environment and runs the tests in a docker container for the S3 only image
	# TODO: We need node as it's a dependency of the InfraProvisioner at import time, remove when we do not need it anymore
	# g++ is a workaround to fix the JPype1 compile error on ARM Linux "gcc: fatal error: cannot execute ‘cc1plus’" because the test dependencies include the runtime dependencies.
	docker run -e LOCALSTACK_INTERNAL_TEST_COLLECT_METRIC=1 --entrypoint= -v `pwd`/requirements-test.txt:/opt/code/localstack/requirements-test.txt -v `pwd`/tests/:/opt/code/localstack/tests/ -v `pwd`/target/:/opt/code/localstack/target/ -v /var/run/docker.sock:/var/run/docker.sock -v /tmp/localstack:/var/lib/localstack \
		$(IMAGE_NAME) \
	    bash -c "apt-get update && apt-get install -y g++ && make install-test && apt-get install -y --no-install-recommends gnupg && mkdir -p /etc/apt/keyrings && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && echo \"deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_18.x nodistro main\" > /etc/apt/sources.list.d/nodesource.list && apt-get update && apt-get install -y --no-install-recommends nodejs && DEBUG=$(DEBUG) PYTEST_LOGLEVEL=$(PYTEST_LOGLEVEL) PYTEST_ARGS='$(PYTEST_ARGS)' TEST_PATH='$(TEST_PATH)' TINYBIRD_PYTEST_ARGS='$(TINYBIRD_PYTEST_ARGS)' TINYBIRD_DATASOURCE='$(TINYBIRD_DATASOURCE)' TINYBIRD_TOKEN='$(TINYBIRD_TOKEN)' TINYBIRD_URL='$(TINYBIRD_URL)' CI_COMMIT_BRANCH='$(CI_COMMIT_BRANCH)' CI_COMMIT_SHA='$(CI_COMMIT_SHA)' CI_JOB_URL='$(CI_JOB_URL)' CI_JOB_NAME='$(CI_JOB_NAME)' CI_JOB_ID='$(CI_JOB_ID)' CI='$(CI)' make test"


docker-cp-coverage:
	@echo 'Extracting .coverage file from Docker image'; \
		id=$$(docker create localstack/localstack); \
		docker cp $$id:/opt/code/localstack/.coverage .coverage; \
		docker rm -v $$id

test:              		  ## Run automated tests
	($(VENV_RUN); $(TEST_EXEC) pytest --durations=10 --log-cli-level=$(PYTEST_LOGLEVEL) $(PYTEST_ARGS) $(TEST_PATH))

test-coverage: LOCALSTACK_INTERNAL_TEST_COLLECT_METRIC = 1
test-coverage: TEST_EXEC = python -m coverage run $(COVERAGE_ARGS) -m
test-coverage: test	  ## Run automated tests and create coverage report

lint:              		  ## Run code linter to check code style, check if formatter would make changes and check if dependency pins need to be updated
	($(VENV_RUN); python -m ruff check --output-format=full . && python -m ruff format --check .)
	$(VENV_RUN); pre-commit run check-pinned-deps-for-needed-upgrade --files pyproject.toml # run pre-commit hook manually here to ensure that this check runs in CI as well


lint-modified:     		  ## Run code linter to check code style, check if formatter would make changes on modified files, and check if dependency pins need to be updated because of modified files
	($(VENV_RUN); python -m ruff check --output-format=full `git diff --diff-filter=d --name-only HEAD | grep '\.py$$' | xargs` && python -m ruff format --check `git diff --diff-filter=d --name-only HEAD | grep '\.py$$' | xargs`)
	$(VENV_RUN); pre-commit run check-pinned-deps-for-needed-upgrade --files $(git diff master --name-only) # run pre-commit hook manually here to ensure that this check runs in CI as well

check-aws-markers:     		  ## Lightweight check to ensure all AWS tests have proper compatibilty markers set
	($(VENV_RUN); python -m pytest --co tests/aws/)

format:            		  ## Run ruff to format the whole codebase
	($(VENV_RUN); python -m ruff format .; python -m ruff check --output-format=full --fix .)

format-modified:          ## Run ruff to format only modified code
	($(VENV_RUN); python -m ruff format `git diff --diff-filter=d --name-only HEAD | grep '\.py$$' | xargs`; python -m ruff check --output-format=full --fix `git diff --diff-filter=d --name-only HEAD | grep '\.py$$' | xargs`)

init-precommit:    		  ## install te pre-commit hook into your local git repository
	($(VENV_RUN); pre-commit install)

clean:             		  ## Clean up (npm dependencies, downloaded infrastructure code, compiled Java classes)
	rm -rf .filesystem
	rm -rf build/
	rm -rf dist/
	rm -rf *.egg-info
	rm -rf $(VENV_DIR)

clean-dist:				  ## Clean up python distribution directories
	rm -rf dist/ build/
	rm -rf *.egg-info

.PHONY: usage freeze install-basic install-runtime install-test install-dev install entrypoints dist publish coveralls start docker-save-image docker-build docker-build-multiarch docker-push-master docker-create-push-manifests docker-run-tests docker-cp-coverage test test-coverage lint lint-modified format format-modified init-precommit clean clean-dist upgrade-pinned-dependencies
