${ALL_TARGETS}: .forward

.PHONY: .forward

MAKE_FORWARD := ${MAKE} ${MAKECMDGOALS}
MAKE_FORWARD += REPODIR=${REPODIR}
MAKE_FORWARD += BUILDDIR=${BUILDDIR}
