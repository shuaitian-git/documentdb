subdir = src/test

check-regress:
	$(MAKE) -C regress all

check-dist-minimal:
	$(MAKE) -C regress $@

installcheck:
	$(MAKE) -C regress installcheck

installcheck-minimal:
	$(MAKE) -C regress $@

check-rbac-minimal:
	$(MAKE) -C regress $@

check-rbac:
	$(MAKE) -C regress check-rbac

all: check-regress check-rbac
