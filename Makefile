.DEFAULT_GOAL := help
SHELL := /bin/bash
VIRTUALENV_ROOT := $(shell [ -z ${VIRTUAL_ENV} ] && echo $$(pwd)/venv || echo ${VIRTUAL_ENV})

PAAS_API ?= api.cloud.service.gov.uk
PAAS_ORG ?= digitalmarketplace
PAAS_SPACE ?= ${STAGE}

define check_space
	$(if ${PAAS_SPACE},,$(error Must specify PAAS_SPACE))
	@[ $$(cf target | grep -i 'space' | cut -d':' -f2) = "${PAAS_SPACE}" ] || (echo "${PAAS_SPACE} is not currently active cf space" && exit 1)
endef

.PHONY: help
help:
	@cat $(MAKEFILE_LIST) | grep -E '^[a-zA-Z_-]+:.*?## .*$$' | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'


.PHONY: test
test: test_pep8 test_unit

.PHONY: test_pep8
test_pep8: virtualenv
	${VIRTUALENV_ROOT}/bin/pep8 .

.PHONY: test_unit
test_unit: virtualenv
	${VIRTUALENV_ROOT}/bin/py.test ${PYTEST_ARGS}

.PHONY: requirements
requirements: virtualenv ## Install requirements
	${VIRTUALENV_ROOT}/bin/pip install -e .

.PHONY: virtualenv
virtualenv: ${VIRTUALENV_ROOT}/activate ## Create virtualenv if it does not exist

${VIRTUALENV_ROOT}/activate:
	@[ -z "${VIRTUAL_ENV}" ] && [ ! -d venv ] && virtualenv venv || true

.PHONY: preview
preview: ## Set stage to preview
	$(eval export STAGE=preview)
	@true

.PHONY: staging
staging: ## Set stage to staging
	$(eval export STAGE=staging)
	@true

.PHONY: production
production: ## Set stage to production
	$(eval export STAGE=production)
	@true

.PHONY: generate-manifest
generate-manifest: virtualenv ## Generate manifest file for PaaS
	$(if ${APPLICATION_NAME},,$(error Must specify APPLICATION_NAME))
	$(if ${STAGE},,$(error Must specify STAGE))
	$(if ${DM_CREDENTIALS_REPO},,$(error Must specify DM_CREDENTIALS_REPO))
	${DM_CREDENTIALS_REPO}/sops-wrapper -v > /dev/null # Avoid asking for MFA twice (when mandatory)
	${VIRTUALENV_ROOT}/bin/dmaws paas-manifest ${STAGE} ${APPLICATION_NAME} \
		-f <(${DM_CREDENTIALS_REPO}/sops-wrapper -d ${DM_CREDENTIALS_REPO}/vars/${STAGE}.yaml)

.PHONY: paas-login
paas-login: ## Log in to PaaS
	$(if ${PAAS_USERNAME},,$(error Must specify PAAS_USERNAME))
	$(if ${PAAS_PASSWORD},,$(error Must specify PAAS_PASSWORD))
	$(if ${PAAS_SPACE},,$(error Must specify PAAS_SPACE))
	@cf login -a "${PAAS_API}" -u ${PAAS_USERNAME} -p "${PAAS_PASSWORD}" -o "${PAAS_ORG}" -s "${PAAS_SPACE}"

.PHONY: deploy-app
deploy-app: ## Deploys the app to PaaS
	$(call check_space)
	$(if ${APPLICATION_NAME},,$(error Must specify APPLICATION_NAME))
	cf push -f <(make -s -C ${CURDIR} generate-manifest) -o digitalmarketplace/${APPLICATION_NAME}:${RELEASE_NAME}

	# TODO restore scaling before route switch once we have autoscaling set up
	# TODO for now, we're using the instance counts set in the manifest
	# cf scale -i $$(cf curl /v2/apps/$$(cf app --guid ${APPLICATION_NAME}-rollback) | jq -r ".entity.instances" 2>/dev/null || echo "1") ${APPLICATION_NAME}

	@if cf app ${APPLICATION_NAME} >/dev/null; then ./scripts/unmap-route.sh ${APPLICATION_NAME}; fi

	@echo "Waiting for previous app version to process existing requests..."
	sleep 60

	cf delete -f ${APPLICATION_NAME}
	cf rename ${APPLICATION_NAME}-release ${APPLICATION_NAME}

.PHONY: deploy-db-migration
deploy-db-migration: ## Deploys the db migration app
	$(if ${APPLICATION_NAME},,$(error Must specify APPLICATION_NAME))
	cf push ${APPLICATION_NAME}-db-migration -f <(make -s -C ${CURDIR} generate-manifest) -o digitalmarketplace/${APPLICATION_NAME}:${RELEASE_NAME} --no-route --health-check-type none -i 1 -m 128M -c 'sleep 2h'
	cf run-task ${APPLICATION_NAME}-db-migration "cd /app && python application.py db upgrade" --name ${APPLICATION_NAME}-db-migration

.PHONY: check-db-migration-task
check-db-migration-task: ## Get the status for the last db migration task
	$(if ${APPLICATION_NAME},,$(error Must specify APPLICATION_NAME))
	@cf curl /v3/apps/`cf app --guid ${APPLICATION_NAME}-db-migration`/tasks?order_by=-created_at | jq -r ".resources[0].state"

.PHONY: paas-clean
paas-clean: ## Cleans up all files created for the PaaS deployment
	cf logout

.PHONY: populate-paas-db
populate-paas-db: ## Imports postgres dump specified with `DB_DUMP=` to targeted spaces db
	$(call check_space)
	$(if ${DB_DUMP},,$(error Must specify DB_DUMP))
	./scripts/populate-paas-db.sh ${DB_DUMP}