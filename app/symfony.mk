### Symfony rules

symfony.check_requirements:
	symfony check:requirements

symfony.security_check:
	docker run --rm -v $(shell pwd):$(shell pwd) -w $(shell pwd) symfonycorp/cli security:check

