WZDIR := $(realpath $(dir $(lastword ${MAKEFILE_LIST}))..)

include ${WZDIR}/core/lib/config.mk
include ${WZDIR}/core/lib/submake.mk
include ${WZDIR}/core/lib/common.mk
include ${WZDIR}/core/lib/forward.mk

DOCKERDIR := ${WZDIR}/docker

DOCKER ?= default
DOCKERFILENAME ?= Dockerfile
DOCKERCONTEXT ?= ${DOCKERDIR}/${DOCKER}
DOCKERFILE ?= ${DOCKERCONTEXT}/${DOCKERFILENAME}

DOCKER_BUILD := docker build
DOCKER_BUILD += -f ${DOCKERFILE}
DOCKER_BUILD += ${DOCKERCONTEXT}

.PHONY: .docker-build
.docker-build:
	${QUIET} ${DOCKER_BUILD}

DOCKER_RUN := docker run
DOCKER_RUN += --rm
DOCKER_RUN += -v ${REPODIR}:${REPODIR}
DOCKER_RUN += -w ${REPODIR}
DOCKER_RUN += -u $$(id -u):$$(id -g)
DOCKER_RUN += $$(${DOCKER_BUILD} -q)

.PHONY: .docker-run
.docker-run: .docker-build
	${DOCKER_RUN} ${MAKE_FORWARD} -f ${WZDIR}/core/config.mk

.forward: .docker-run
